# Shared settings for Python images. Sourced by profiles.

# Standard-library folders kept whole even if a probe never touched
# them: text codecs (a station can send any charset), C extensions,
# and the XML/HTTP/e-mail/URL/JSON packages that load parts lazily.
# About 8.5 MB; cheap insurance against a rare code path breaking.
# Argument: the image's stdlib folder, for example /usr/local/lib/python3.13
python_safety_includes() {
    local lib="$1" sub
    for sub in encodings lib-dynload xml email http urllib json; do
        MINT_EXTRA+=(--include-path "$lib/$sub")
    done
}
