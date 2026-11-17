#!/usr/bin/env python3
"""Answer MPD status/currentsong requests from a scripted scenario.

Used by slim-image.sh profiles to exercise MPD clients (such as the radio
scrobbler) without touching the real MPD or what it is playing.

Input: a JSON scenario file, a list of steps such as
    [{"seconds": 6, "status": {"state": "stop"}, "song": {}}, ...]
Each step is served for its "seconds", counted from start-up; the last
step repeats forever. Only the read-only commands status, currentsong
and ping (alone or inside a command list) are answered; anything else
gets an ACK, so a client can never change playback here.

Output: none besides the MPD protocol on 127.0.0.1:<port>.
"""

import argparse
import json
import socketserver
import time
from pathlib import Path

READ_ONLY = {"status", "currentsong", "ping"}


def load_scenario(path: Path) -> list[dict]:
    """Read and validate the scenario steps."""
    steps = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(steps, list) or not steps:
        raise ValueError("scenario must be a non-empty JSON list")
    for step in steps:
        if not isinstance(step.get("seconds"), (int, float)):
            raise ValueError("every step needs a numeric 'seconds'")
    return steps


class Handler(socketserver.StreamRequestHandler):
    """Serve one MPD client connection."""

    def current(self) -> dict:
        """Return the step for the time since the server started."""
        elapsed = time.monotonic() - self.server.started
        for step in self.server.steps:
            if elapsed < step["seconds"]:
                return step
            elapsed -= step["seconds"]
        return self.server.steps[-1]

    def answer(self, command: str) -> bool:
        """Write one command's response lines; False for unknown commands."""
        if command not in READ_ONLY:
            return False
        step = self.current()
        fields = {"status": step.get("status", {}),
                  "currentsong": step.get("song", {})}.get(command, {})
        for key, value in fields.items():
            self.wfile.write(f"{key}: {value}\n".encode())
        return True

    def handle(self) -> None:
        self.wfile.write(b"OK MPD 0.24.0\n")
        in_list = False
        for raw in self.rfile:
            command = raw.decode("utf-8", "replace").strip()
            if command in ("command_list_ok_begin", "command_list_begin"):
                in_list = True
                continue
            if command == "command_list_end":
                in_list = False
                self.wfile.write(b"OK\n")
                continue
            if command == "close":
                return
            if not self.answer(command):
                self.wfile.write(f"ACK [5@0] {{{command}}} unknown command\n".encode())
                continue
            self.wfile.write(b"list_OK\n" if in_list else b"OK\n")


class Server(socketserver.ThreadingTCPServer):
    """Threaded server holding the scenario and its start time."""

    allow_reuse_address = True
    daemon_threads = True


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("-p", "--port", type=int, required=True,
                        help="TCP port to listen on (127.0.0.1 only)")
    parser.add_argument("-s", "--scenario", type=Path, required=True,
                        help="JSON file with the scripted playback steps")
    args = parser.parse_args()
    with Server(("127.0.0.1", args.port), Handler) as server:
        server.steps = load_scenario(args.scenario)
        server.started = time.monotonic()
        server.serve_forever()


if __name__ == "__main__":
    main()
