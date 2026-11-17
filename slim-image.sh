#!/usr/bin/bash
# Build and check minified ("slim") Docker images for the homelab stacks
# with mint (formerly DockerSlim / SlimToolkit), run from its own Docker
# image so nothing is installed on the host.
#
# Usage:
#   slim-image.sh build  <profile>   pull the source image, run it with the
#                                    profile's probes, write the slim image
#   slim-image.sh verify <profile>   run the source and slim images with the
#                                    same arguments and compare check output
#   slim-image.sh sizes  <profile>   show both image sizes
#   slim-image.sh list               list the profiles
#
# A profile is profiles/<name>.conf (a Bash file). It sets:
#   SOURCE_IMAGE   image to minify (pulled first unless PULL_SOURCE=0)
#   SLIM_IMAGE     tag for the result (local only; compose uses pull_policy: never)
#   NETWORK        Docker network for the test run (default: host)
#   PORTS          array of host:container port mappings for a bridge network
#   RUN_USER       user:group for verify runs, as in the stack (mint's
#                  analysis run uses the image's own USER instead)
#   MOUNTS         array of src:dst[:ro] bind mounts (use $WORK for data copies)
#   ENVS           array of KEY=VALUE environment variables
#   ENV_FILE       optional env file (secrets stay in the stack's .env)
#   ENTRYPOINT     optional JSON array overriding the entrypoint
#   CMD            optional JSON array with the container arguments
#   MINT_EXTRA     array of extra mint flags (--include-path and similar)
# and may define these functions:
#   prepare        copy the stack's data into $WORK (never use the live ./data)
#   wait_ready     return 0 once the container in $CONTAINER is serving
#   probe          exercise every code path while mint watches
#   check          print normalized lines describing behavior; verify diffs
#                  the source image's lines against the slim image's lines
#   cleanup        stop helpers prepare() started (runs before each prepare
#                  and on exit; must be safe to call when nothing runs)
#
# Test runs never touch a stack's live ./data: prepare() copies it into
# $WORK under /home/william/tmp/scratchpad/slim-work/<profile>.

set -Eeuo pipefail

MINT_IMAGE="mintoolkit/mint:1.41.8"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_ROOT="/home/william/tmp/scratchpad/slim-work"
READY_TIMEOUT=120

usage() {
    sed -n '2,/^$/{s/^# \{0,1\}//;p}' "$0"
    exit "${1:-0}"
}

log() {
    printf '[%s] %s\n' "$(date '+%I:%M:%S %p')" "$*" >&2
}

# Load a profile and set defaults for anything it leaves out.
load_profile() {
    local name="$1"
    local file="$SCRIPT_DIR/profiles/$name.conf"
    if [[ ! "$name" =~ ^[a-z0-9-]+$ || ! -f "$file" ]]; then
        echo "Unknown profile: $name (see: $0 list)" >&2
        exit 2
    fi
    PROFILE="$name"
    WORK="$WORK_ROOT/$name"
    NETWORK="host"
    RUN_USER=""
    MOUNTS=()
    PORTS=()
    ENVS=()
    ENV_FILE=""
    ENTRYPOINT=""
    CMD=""
    MINT_EXTRA=()
    PULL_SOURCE=1
    prepare() { :; }
    wait_ready() { sleep 5; }
    probe() { :; }
    check() { :; }
    cleanup() { :; }
    # shellcheck source=/dev/null
    source "$file"
    trap cleanup EXIT
    : "${SOURCE_IMAGE:?profile must set SOURCE_IMAGE}"
    : "${SLIM_IMAGE:?profile must set SLIM_IMAGE}"
}

# Wait for wait_ready() to succeed, failing after READY_TIMEOUT seconds.
wait_for_ready() {
    local deadline=$((SECONDS + READY_TIMEOUT))
    until wait_ready; do
        if ! docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null | grep -q true; then
            log "Container $CONTAINER stopped before it was ready:"
            docker logs --tail 40 "$CONTAINER" >&2 || true
            return 1
        fi
        if ((SECONDS > deadline)); then
            log "Container $CONTAINER was not ready after ${READY_TIMEOUT}s"
            docker logs --tail 40 "$CONTAINER" >&2 || true
            return 1
        fi
        sleep 2
    done
}

# Turn a JSON array into one argument per line for docker run.
json_args() {
    python3 -c 'import json,sys; [print(a) for a in json.loads(sys.argv[1])]' "$1"
}

# Change the owner of $WORK without sudo, from a throwaway container.
# Argument: uid[:gid] as in an image's USER (numeric).
own_work() {
    local owner="$1"
    [[ "$owner" == *:* ]] || owner="$owner:$owner"
    if [[ ! "$owner" =~ ^[0-9]+:[0-9]+$ ]]; then
        log "Image USER '$1' is not numeric; leaving $WORK as it is"
        return 0
    fi
    docker run --rm --network none -v "$WORK:/work" alpine:3.24 chown -R "$owner" /work
}

fresh_work() {
    mkdir -p "$WORK_ROOT"
    chmod 700 "$WORK_ROOT"
    if [[ -d "$WORK" ]]; then
        # A run that stopped early can leave copies owned by another user.
        rm -rf -- "$WORK" 2>/dev/null || {
            own_work "$(id -u):$(id -g)"
            rm -rf -- "$WORK"
        }
    fi
    cleanup
    mkdir -p "$WORK"
    prepare
}

cmd_build() {
    load_profile "$1"
    if [[ "$PULL_SOURCE" == 1 ]]; then
        log "Pulling $SOURCE_IMAGE"
        docker pull --quiet "$SOURCE_IMAGE" >/dev/null
    fi
    local source_id
    source_id="$(docker image inspect -f '{{.Id}}' "$SOURCE_IMAGE")"
    fresh_work
    # mint's sensor cannot switch to a numeric user the image has no
    # account for, so the analysis run uses the image's own USER. Hand the
    # scratch copies to that user (apps may insist on owning private
    # config files) and take them back afterwards.
    local image_user
    image_user="$(docker image inspect -f '{{.Config.User}}' "$SOURCE_IMAGE")"
    [[ -n "$image_user" ]] && own_work "$image_user"

    local args=(slim --target "$SOURCE_IMAGE" --tag "$SLIM_IMAGE" --pull=false
        --network "$NETWORK" --continue-after signal --http-probe-off
        --show-clogs --new-label "slim.source=$SOURCE_IMAGE"
        --new-label "slim.source-id=$source_id")
    [[ -n "$ENTRYPOINT" ]] && args+=(--entrypoint "$ENTRYPOINT")
    [[ -n "$CMD" ]] && args+=(--cmd "$CMD")
    local item target
    for item in "${MOUNTS[@]}"; do
        args+=(--mount "$item")
        # mint's own --exclude-mounts does not see these mounts when it
        # runs in a container, so exclude each mount target explicitly:
        # test data and credential copies must never end up in the image.
        target="$(mount_target "$item")"
        args+=(--exclude-pattern "$target" --exclude-pattern "$target/**")
    done
    for item in "${PORTS[@]}"; do args+=(--publish-port "$item"); done
    for item in "${ENVS[@]}"; do args+=(--env "$item"); done
    if [[ -n "$ENV_FILE" ]]; then
        # mint reads the env file inside its own container, so pass the
        # values one by one instead of mounting the secrets file.
        while IFS= read -r item; do
            [[ -z "$item" || "$item" == \#* ]] && continue
            args+=(--env "$item")
        done <"$ENV_FILE"
    fi
    args+=("${MINT_EXTRA[@]}")

    local mint_name="mint-slim-$PROFILE"
    docker rm -fv "$mint_name" >/dev/null 2>&1 || true
    log "Starting mint for $SOURCE_IMAGE"
    docker run -d --name "$mint_name" --network host \
        -v /var/run/docker.sock:/var/run/docker.sock \
        "$MINT_IMAGE" --archive-state off --in-container "${args[@]}" >/dev/null

    # mint starts the target from the source image; find that container.
    CONTAINER=""
    local deadline=$((SECONDS + 120))
    while [[ -z "$CONTAINER" ]]; do
        CONTAINER="$(docker ps -q --filter "ancestor=$source_id" --filter 'name=mint' | head -n 1)"
        if ((SECONDS > deadline)) || ! docker inspect -f '{{.State.Running}}' "$mint_name" | grep -q true; then
            log "mint did not start the target container:"
            docker logs "$mint_name" >&2 || true
            docker rm -fv "$mint_name" >/dev/null 2>&1 || true
            return 1
        fi
        [[ -z "$CONTAINER" ]] && sleep 1
    done
    log "Target container: $CONTAINER"
    # mint leaves the target's artifact volume (a copy of every kept file)
    # behind; note it so it can be removed afterwards.
    local artifacts
    artifacts="$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/opt/_mint/artifacts"}}{{.Name}}{{end}}{{end}}' "$CONTAINER")"

    local status=0
    if wait_for_ready; then
        log "Running probes"
        probe || status=$?
        ((status == 0)) || log "probe() failed with exit code $status"
    else
        status=1
    fi
    log "Telling mint to finish"
    docker kill -s USR1 "$mint_name" >/dev/null
    docker wait "$mint_name" >/dev/null
    docker logs "$mint_name" 2>&1 | grep -vE '^cmd=slim info=(container.logs|probe)' | tail -n 25 >&2
    # -v also removes mint's anonymous state volume (another copy of the files).
    docker rm -v "$mint_name" >/dev/null
    if [[ -n "$artifacts" ]]; then
        # mint removes the target container shortly after it exits.
        local tries=0
        until docker volume rm "$artifacts" >/dev/null 2>&1 || ! docker volume inspect "$artifacts" >/dev/null 2>&1; do
            if ((++tries > 15)); then
                log "Could not remove mint volume $artifacts; remove it by hand"
                break
            fi
            sleep 2
        done
    fi
    if ((status == 0)) && ! audit_image; then
        status=1
    fi
    # Take the copies back (an image without USER writes them as root).
    own_work "$(id -u):$(id -g)"
    rm -rf -- "$WORK"
    if ((status != 0)); then
        log "Probes failed; removing $SLIM_IMAGE"
        docker image rm "$SLIM_IMAGE" >/dev/null 2>&1 || true
        return "$status"
    fi
    cmd_sizes_loaded
}

# Print the container path of a src:dst[:ro] mount.
mount_target() {
    local rest="${1#*:}"
    echo "${rest%%:*}"
}

# Fail if the slim image holds any mounted path or a secret from ENV_FILE.
audit_image() {
    local listing item target bad=0
    listing="$(mktemp)"
    local container
    container="$(docker create "$SLIM_IMAGE")"
    docker export "$container" | tar -t >"$listing"
    docker rm "$container" >/dev/null
    for item in "${MOUNTS[@]}"; do
        target="$(mount_target "$item")"
        # Bare directory entries (a declared VOLUME's empty mount point)
        # are fine; any file under a mounted path is not.
        if grep -xE "${target#/}(/.*)?" "$listing" | grep -v '/$' >"$listing.hits"; then
            log "AUDIT: $SLIM_IMAGE contains mounted path $target:"
            head -n 5 "$listing.hits" >&2
            bad=1
        fi
        rm -f "$listing.hits"
    done
    if [[ -n "$ENV_FILE" ]]; then
        local key
        while IFS='=' read -r key _; do
            [[ -z "$key" || "$key" == \#* ]] && continue
            if docker image inspect -f '{{json .Config.Env}}' "$SLIM_IMAGE" | grep -q "\"$key="; then
                log "AUDIT: $SLIM_IMAGE stores $key from $ENV_FILE in its environment"
                bad=1
            fi
        done <"$ENV_FILE"
    fi
    rm -f "$listing"
    if ((bad)); then
        return 1
    fi
    log "Audit: no mounted paths or env-file secrets in $SLIM_IMAGE"
}

# Run one image the way the profile describes and print check() output.
run_check() {
    local image="$1" label="$2"
    fresh_work
    local args=(run -d --name "slim-verify-$PROFILE-$label" --network "$NETWORK")
    [[ -n "$RUN_USER" ]] && args+=(--user "$RUN_USER")
    [[ -n "$ENV_FILE" ]] && args+=(--env-file "$ENV_FILE")
    local item
    for item in "${MOUNTS[@]}"; do args+=(-v "$item"); done
    for item in "${PORTS[@]}"; do args+=(-p "$item"); done
    for item in "${ENVS[@]}"; do args+=(-e "$item"); done
    if [[ -n "$ENTRYPOINT" ]]; then
        mapfile -t entry < <(json_args "$ENTRYPOINT")
        args+=(--entrypoint "${entry[0]}" "$image" "${entry[@]:1}")
    else
        args+=("$image")
    fi
    if [[ -n "$CMD" ]]; then
        mapfile -t extra < <(json_args "$CMD")
        args+=("${extra[@]}")
    fi
    CONTAINER="slim-verify-$PROFILE-$label"
    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
    docker "${args[@]}" >/dev/null
    local status=0
    if wait_for_ready; then
        check >"$WORK_ROOT/$PROFILE.$label.check" || status=$?
    else
        status=1
    fi
    docker logs "$CONTAINER" >"$WORK_ROOT/$PROFILE.$label.log" 2>&1 || true
    docker rm -f "$CONTAINER" >/dev/null
    return "$status"
}

cmd_verify() {
    load_profile "$1"
    mkdir -p "$WORK_ROOT"
    log "Checking source image $SOURCE_IMAGE"
    run_check "$SOURCE_IMAGE" source
    log "Checking slim image $SLIM_IMAGE"
    run_check "$SLIM_IMAGE" slim
    local failed=0
    if diff -u "$WORK_ROOT/$PROFILE.source.check" "$WORK_ROOT/$PROFILE.slim.check"; then
        log "check() output matches ($(wc -l <"$WORK_ROOT/$PROFILE.slim.check") lines)"
    else
        log "check() output differs"
        failed=1
    fi
    # Errors the source image does not also log point at missing files.
    local pattern='Traceback|ModuleNotFoundError|ImportError|No such file|not found|cannot open shared object|Error loading|ENOENT|segmentation'
    local source_hits slim_hits
    source_hits="$(grep -ciE "$pattern" "$WORK_ROOT/$PROFILE.source.log" || true)"
    slim_hits="$(grep -ciE "$pattern" "$WORK_ROOT/$PROFILE.slim.log" || true)"
    if ((slim_hits > source_hits)); then
        log "Slim log has $slim_hits error lines, source has $source_hits:"
        grep -iE "$pattern" "$WORK_ROOT/$PROFILE.slim.log" | head -n 20 >&2
        failed=1
    else
        log "Logs: slim $slim_hits error lines, source $source_hits"
    fi
    log "Logs: $WORK_ROOT/$PROFILE.{source,slim}.log"
    rm -rf -- "$WORK"
    return "$failed"
}

cmd_sizes_loaded() {
    docker image ls --format '{{.Repository}}:{{.Tag}}\t{{.Size}}' |
        grep -E "^(${SOURCE_IMAGE}|${SLIM_IMAGE})	" || true
}

main() {
    local action="${1:-}"
    case "$action" in
        build | verify)
            [[ $# -eq 2 ]] || usage 2
            "cmd_$action" "$2"
            ;;
        sizes)
            [[ $# -eq 2 ]] || usage 2
            load_profile "$2"
            cmd_sizes_loaded
            ;;
        list)
            find "$SCRIPT_DIR/profiles" -name '*.conf' -printf '%f\n' | sed 's/\.conf$//' | sort
            ;;
        -h | --help | "") usage 0 ;;
        *) usage 2 ;;
    esac
}

# One line, so editing this file while it runs cannot change what runs next.
main "$@"; exit $?
