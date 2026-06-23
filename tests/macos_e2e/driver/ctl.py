"""Wrapper around the `wisptermctl` CLI. Every call runs the binary with a fixed
HOME so it auto-discovers (and only ever talks to) the isolated test instance.
"""
import json
import os
import subprocess

from . import wait


class Ctl:
    def __init__(self, home: str, binary: str):
        self.home = home
        self.binary = binary

    def _run(self, args, timeout: float = 10.0) -> str:
        env = dict(os.environ)
        env["HOME"] = self.home
        proc = subprocess.run(
            [self.binary, *args],
            capture_output=True, text=True, env=env, timeout=timeout,
        )
        if proc.returncode != 0:
            raise RuntimeError(f"wisptermctl {args} failed: {proc.stderr.strip()}")
        return proc.stdout

    def panes(self) -> dict:
        return json.loads(self._run(["panes"]))

    def ui_state(self) -> dict:
        # Overlay semantic layer (active overlay, command-palette selection/filter,
        # session launcher, settings) — complements `panes` (topology).
        return json.loads(self._run(["ui-state"]))

    def get_text(self, pane: str, recent=None) -> str:
        args = ["get-text", "-t", pane]
        if recent is not None:
            args += ["--recent", str(recent)]
        return self._run(args)

    def send_text(self, pane: str, data: str) -> None:
        # Injects bytes straight into the surface via the control server,
        # bypassing the OS input path (see issue #279). `data` may contain a
        # literal newline to submit a command.
        self._run(["send-text", "-t", pane, data])

    def wait_for(self, pane: str, pattern: str, timeout: float = 5.0,
                 interval: float = 0.2, clock=wait._RealClock) -> None:
        wait.wait_until(
            lambda: wait.matches(self.get_text(pane), pattern),
            timeout=timeout, interval=interval, clock=clock,
        )
