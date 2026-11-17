"""Tests for tools/fake-mpd.py: scripted answers and refusal of changes."""

import json
import socket
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

TOOL = Path(__file__).resolve().parent.parent / "tools" / "fake-mpd.py"


def free_port() -> int:
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


class FakeMpdTest(unittest.TestCase):
    """Start the fake MPD with a two-step scenario and query it."""

    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        scenario = Path(self.folder.name) / "scenario.json"
        scenario.write_text(json.dumps([
            {"seconds": 1, "status": {"state": "stop"}, "song": {}},
            {"seconds": 5, "status": {"state": "play", "songid": "7"},
             "song": {"file": "a.mp3", "Title": "Song"}},
        ]))
        self.port = free_port()
        self.server = subprocess.Popen(
            [sys.executable, str(TOOL), "-p", str(self.port), "-s", str(scenario)])
        for _ in range(50):
            try:
                socket.create_connection(("127.0.0.1", self.port), 0.2).close()
                break
            except OSError:
                time.sleep(0.1)

    def tearDown(self):
        self.server.terminate()
        self.server.wait(5)
        self.folder.cleanup()

    def ask(self, *commands: str) -> list[str]:
        with socket.create_connection(("127.0.0.1", self.port), 5) as conn:
            reader = conn.makefile("r")
            self.assertTrue(reader.readline().startswith("OK MPD"))
            conn.sendall(("\n".join(commands) + "\nclose\n").encode())
            return [line.rstrip("\n") for line in reader]

    def test_command_list_follows_the_scenario(self):
        lines = self.ask("command_list_ok_begin", "status", "currentsong", "command_list_end")
        self.assertEqual(lines, ["state: stop", "list_OK", "list_OK", "OK"])
        time.sleep(1.2)
        lines = self.ask("command_list_ok_begin", "status", "currentsong", "command_list_end")
        self.assertIn("state: play", lines)
        self.assertIn("Title: Song", lines)

    def test_commands_that_change_playback_are_refused(self):
        for command in ("play", "clear", "add a.mp3"):
            lines = self.ask(command)
            self.assertTrue(lines[0].startswith("ACK"), lines)


if __name__ == "__main__":
    unittest.main()
