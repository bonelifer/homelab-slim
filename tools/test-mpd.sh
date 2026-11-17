#!/usr/bin/bash
# Run a throwaway MPD for slim-image.sh profiles whose app changes MPD's
# queue or playback, so tests never touch the live MPD.
#
# Usage:
#   test-mpd.sh start <port> <workdir> [image]   start MPD on 127.0.0.1:<port>
#   test-mpd.sh stop  <port>                     stop and remove it
#
# start copies the live mpd-alsa database, state and playlists into
# <workdir>/mpd, mounts ~/Music read-only and plays to a null output
# (no sound card, no PulseAudio, no HTTP stream). The container is named
# test-mpd-<port>. Output: the container name on stdout.

set -Eeuo pipefail

STACK="/home/william/Desktop/hl/dockhand/data/stacks/mpd-alsa"
MUSIC="/home/william/Music"

start() {
    local port="$1" work="$2" image="${3:-giof71/mpd-alsa}"
    local name="test-mpd-$port"
    [[ "$port" =~ ^[0-9]+$ && "$port" != 6600 ]] || { echo "Bad port: $port" >&2; exit 2; }
    mkdir -p "$work/mpd/db" "$work/mpd/config" "$work/mpd/log" "$work/mpd/playlists"
    cp -p "$STACK/data/db/tag_cache" "$STACK/data/db/sticker" "$STACK/data/db/state" "$work/mpd/db/"
    cp -p "$STACK/data/playlists/"*.m3u "$work/mpd/playlists/"
    docker rm -f "$name" >/dev/null 2>&1 || true
    docker run -d --name "$name" --network host --hostname test-mpd \
        -e PUID="$(id -u)" -e PGID="$(id -g)" -e TZ=America/Chicago \
        -e MPD_PORT="$port" -e MPD_BIND_ADDRESS=127.0.0.1 -e AUTO_UPDATE=no \
        -e ENFORCE_PLAYER_STATE=no -e MAX_OUTPUT_BUFFER_SIZE=32768 \
        -e PULSE_AUDIO_OUTPUT_CREATE=no -e HTTPD_OUTPUT_CREATE=no \
        -e NULL_OUTPUT_CREATE=yes -e NULL_OUTPUT_NAME=null \
        -v "$work/mpd/config:/user/config" -v "$work/mpd/db:/db" \
        -v "$work/mpd/log:/log" -v "$work/mpd/playlists:/playlists" \
        -v "$MUSIC:/music:ro" "$image" >/dev/null
    # Wait for the MPD greeting (the database load takes a few seconds).
    local tries=0
    until python3 -c 'import socket,sys; s=socket.create_connection(("127.0.0.1", int(sys.argv[1])), 2); sys.exit(0 if s.recv(64).startswith(b"OK MPD") else 1)' "$port" 2>/dev/null; do
        if ((++tries > 60)) || ! docker inspect -f '{{.State.Running}}' "$name" | grep -q true; then
            echo "Test MPD did not start:" >&2
            docker logs --tail 30 "$name" >&2 || true
            exit 1
        fi
        sleep 1
    done
    echo "$name"
}

stop() {
    docker rm -f "test-mpd-$1" >/dev/null 2>&1 || true
}

case "${1:-}" in
    start) [[ $# -ge 3 ]] || { sed -n '2,13p' "$0"; exit 2; }; start "$2" "$3" "${4:-}" ;;
    stop) [[ $# -eq 2 ]] || { sed -n '2,13p' "$0"; exit 2; }; stop "$2" ;;
    *) sed -n '2,13p' "$0"; exit 2 ;;
esac
