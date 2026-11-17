#!/usr/bin/env python3
"""Exercise a test MPD for the mpd-alsa slim profile.

Runs database, tag, decoder, playback, output, playlist and sticker
commands against the MPD on 127.0.0.1:<port>, and prints one normalized
line per step (status and the facts that should not vary between two
runs), so the source and slim images can be compared line by line.

Never point this at the live MPD: it clears the queue, plays, writes
stickers and saves playlists.

Inputs: --port (MPD), --stream-port (its HTTP output), --music (host
path of the music folder, used to pick sample files).
Output: lines on stdout; exit code 0 unless the MPD cannot be reached.
"""

import argparse
import json
import socket
import sys
import time
import urllib.request
from pathlib import Path

# Stream types the radio bridges hand MPD. SomaFM is fixed; iHeart and
# TuneIn URLs come from the live bridges' read-only lookups. Pandora is
# left out: its account allows one stream at a time, so a test stream
# could cut off real listening (its stream is plain HTTP MP3, as SomaFM's
# http:// one below). iBroadcast's bridge serves HTTP MP3 tracks.
def streams() -> list[tuple[str, str]]:
    found = [("somafm https mp3", "https://ice1.somafm.com/groovesalad-128-mp3"),
             ("somafm http aac", "http://ice1.somafm.com/groovesalad-128-aac")]
    for label, base in (("iheart", "http://127.0.0.1:18767"),
                        ("tunein", "http://127.0.0.1:18766")):
        try:
            with urllib.request.urlopen(base + "/stations", timeout=30) as response:
                first = json.load(response)[0]["id"]
            with urllib.request.urlopen(f"{base}/stations/{first}", timeout=30) as response:
                found.append((label, json.load(response)["url"]))
        except (OSError, ValueError, KeyError, IndexError):
            print(f"{label}: bridge lookup failed, stream skipped", flush=True)
    try:
        with urllib.request.urlopen("http://127.0.0.1:18769/browse?mode=random&value=1",
                                    timeout=60) as response:
            track = json.load(response)[0]["id"]
        found.append(("ibroadcast", f"http://127.0.0.1:18769/stream/{track}"))
    except (OSError, ValueError, KeyError, IndexError):
        print("ibroadcast: bridge lookup failed, stream skipped", flush=True)
    return found

UPDATE_DIRS = ("library/explo", "library/Kris Kristofferson/Kristofferson (2010)")


class Mpd:
    """Minimal MPD protocol client."""

    def __init__(self, port: int):
        self.sock = socket.create_connection(("127.0.0.1", port), 10)
        self.file = self.sock.makefile("rwb")
        if not self.file.readline().startswith(b"OK MPD"):
            raise OSError("not an MPD server")

    def call(self, *args: str) -> tuple[str, list[tuple[str, str]]]:
        """Send one command; return ("OK" or the ACK text, key/value pairs)."""
        line = " ".join([args[0]] + ['"' + a.replace("\\", "\\\\").replace('"', '\\"') + '"'
                                      for a in args[1:]])
        self.file.write(line.encode() + b"\n")
        self.file.flush()
        pairs = []
        while True:
            raw = self.file.readline()
            if not raw:
                raise OSError("connection closed")
            if raw.startswith(b"binary: "):
                size = int(raw.split(b": ")[1])
                self.file.read(size + 1)
                pairs.append(("binary", str(size)))
                continue
            text = raw.decode("utf-8", "replace").rstrip("\n")
            if text == "OK":
                return "OK", pairs
            if text.startswith("ACK"):
                return "ACK", pairs
            key, _, value = text.partition(": ")
            pairs.append((key, value))

    def value(self, key: str, *args: str) -> str:
        """Return the first value for key from a command's reply."""
        return dict(self.call(*args)[1]).get(key, "")


def step(label: str, result: str, detail="") -> None:
    print(f"{label}: {result}" + (f" {detail}" if detail != "" else ""), flush=True)


def wait_update(mpd: Mpd) -> None:
    """Wait for a database update to finish (max 5 minutes)."""
    deadline = time.monotonic() + 300
    while "updating_db" in dict(mpd.call("status")[1]):
        if time.monotonic() > deadline:
            raise TimeoutError("update still running")
        time.sleep(1)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--port", type=int, required=True, help="test MPD port")
    parser.add_argument("--stream-port", type=int, required=True,
                        help="test MPD's HTTP output port")
    parser.add_argument("--music", type=Path, required=True,
                        help="host path of the music folder MPD serves")
    args = parser.parse_args()
    if args.port == 6600:
        parser.error("refusing to touch the live MPD on port 6600")
    mpd = Mpd(args.port)

    # Plugin lists must match exactly between the source and slim images.
    for command, key in (("decoders", "plugin"), ("outputs", "plugin"),
                         ("urlhandlers", "handler"), ("tagtypes", "tagtype")):
        result, pairs = mpd.call(command)
        step(command, result, " ".join(v for k, v in pairs if k == key))
    for command in ("status", "stats", "commands", "listmounts", "listneighbors"):
        result, pairs = mpd.call(command)
        step(command, result, len(pairs) > 0)
    # idle is what myMPD and the scripts wait on; noidle ends it.
    mpd.file.write(b"idle\n")
    mpd.file.flush()
    time.sleep(0.5)
    step("idle/noidle", mpd.call("noidle")[0])

    for folder in UPDATE_DIRS:
        result, _ = mpd.call("update", folder)
        wait_update(mpd)
        step("update " + folder.split("/")[-1], result,
             mpd.call("lsinfo", folder)[0])
    result, _ = mpd.call("rescan", UPDATE_DIRS[0])
    wait_update(mpd)
    step("rescan", result)

    m4a = next(args.music.rglob("*.m4a")).relative_to(args.music).as_posix()
    mp3 = next((args.music / UPDATE_DIRS[0]).rglob("*.mp3")).relative_to(args.music).as_posix()
    for label, uri in (("mp3", mp3), ("m4a", m4a)):
        step(f"readcomments {label}", mpd.call("readcomments", uri)[0])
        step(f"albumart {label}", mpd.call("albumart", uri, "0")[0])
        step(f"readpicture {label}", mpd.call("readpicture", uri, "0")[0])
        step(f"getfingerprint {label}", mpd.call("getfingerprint", uri)[0])
    for command, query in (("find", ("artist", "Zedd")), ("search", ("any", "love")),
                           ("list", ("album",)), ("count", ("genre", "Rock"))):
        result, pairs = mpd.call(command, *query)
        step(command, result, len(pairs) > 0)
    step("listallinfo", mpd.call("listallinfo", UPDATE_DIRS[1])[0])

    # Playback: volume 0 first so the PulseAudio output stays silent.
    mpd.call("stop")
    mpd.call("clear")
    items = [("mp3", mp3), ("m4a", m4a)] + streams()
    for label, uri in items:
        step("add " + label, mpd.call("add", uri)[0])
    for name, value in (("consume", "0"), ("random", "0"), ("repeat", "0"),
                        ("replay_gain_mode", "track")):
        step(name, mpd.call(name, value)[0])
    step("replay_gain_status", mpd.value("replay_gain_mode", "replay_gain_status"))
    step("play", mpd.call("play", "0")[0])
    step("setvol 0", mpd.call("setvol", "0")[0])
    for position, (label, _) in enumerate(items):
        if position:
            mpd.call("play", str(position))
        time.sleep(4 if position < 2 else 7)
        first = dict(mpd.call("status")[1])
        time.sleep(2)
        second = dict(mpd.call("status")[1])
        advancing = float(second.get("elapsed", 0)) > float(first.get("elapsed", 0))
        step(f"playing {label}", second.get("state"),
             f"song={second.get('song')} elapsed advancing={advancing}")
        if label == "mp3":
            try:
                with urllib.request.urlopen(f"http://127.0.0.1:{args.stream_port}/",
                                            timeout=10) as response:
                    data = response.read(65536)
                step("http stream", response.status, len(data) == 65536)
            except OSError as error:
                step("http stream", "failed", type(error).__name__)
            step("seekcur", mpd.call("seekcur", "30")[0])
    step("stop", mpd.call("stop")[0])

    step("save", mpd.call("save", "slimtest")[0])
    step("listplaylistinfo", mpd.call("listplaylistinfo", "slimtest")[0])
    step("load", mpd.call("load", "slimtest")[0])
    step("rm", mpd.call("rm", "slimtest")[0])
    step("listplaylists", mpd.call("listplaylists")[0])
    step("sticker set", mpd.call("sticker", "set", "song", mp3, "rating", "5")[0])
    step("sticker get", mpd.value("sticker", "sticker", "get", "song", mp3, "rating"))
    step("sticker find", mpd.call("sticker", "find", "song", UPDATE_DIRS[0], "rating")[0])
    step("sticker delete", mpd.call("sticker", "delete", "song", mp3, "rating")[0])
    step("lsinfo root", mpd.call("lsinfo")[0])
    mpd.call("clear")
    return 0


if __name__ == "__main__":
    sys.exit(main())
