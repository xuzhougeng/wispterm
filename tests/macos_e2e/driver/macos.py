"""macOS backend: composes Quartz input + osascript (menu/AX) + wisptermctl
(text), and owns the isolated WispTerm.app instance lifecycle.
"""
import os
import signal
import subprocess
import tempfile
import time

from . import keycodes, osascript, quartz_input, wait
from .base import ItemState
from .ctl import Ctl
from .panes import primary_pane_id

_CONFIG = (
    "agent-control-enabled = true\n"
    "auto-update-check = false\n"
    "font-size = 14\n"
)


class MacDriver:
    def __init__(self, app_bundle: str, ctl_binary: str):
        # app_bundle: .../zig-out/bin/WispTerm.app ; ctl_binary: .../zig-out/bin/wisptermctl
        self.app_bundle = app_bundle
        self.ctl_binary = ctl_binary
        self.home = tempfile.mkdtemp(prefix="wispterm-e2e-")
        self.pid = None
        self.ctl = Ctl(home=self.home, binary=self.ctl_binary)

    @staticmethod
    def _wispterm_pids() -> set:
        out = subprocess.run(["/usr/bin/pgrep", "-x", "WispTerm"],
                             capture_output=True, text=True).stdout
        return set(out.split())

    def _new_pid(self, before: set):
        new = self._wispterm_pids() - before
        return int(sorted(new)[0]) if new else None

    # ---- lifecycle ----
    def _config_dir(self) -> str:
        return os.path.join(self.home, "Library", "Application Support", "wispterm")

    def launch(self, *, cols: int = 80, rows: int = 24) -> None:
        cfg_dir = self._config_dir()
        os.makedirs(cfg_dir, exist_ok=True)
        with open(os.path.join(cfg_dir, "config"), "w") as f:
            f.write(_CONFIG)

        env = dict(os.environ)
        env["HOME"] = self.home

        # Launch via LaunchServices (`open`), NOT a direct exec of the bundle
        # binary. A directly-exec'd GUI app gets a broken Input Method Kit
        # connection ("error messaging the mach port for IMKCFRunLoopWakeUpReliable"),
        # so synthetic keyboard text never reaches the terminal while mouse / AX /
        # the control channel all still work. `open` performs a proper activation
        # and (verified) propagates our custom HOME, preserving isolation. `-n`
        # forces a fresh instance even if a dev instance is already running.
        before = self._wispterm_pids()
        subprocess.run(["/usr/bin/open", "-n", "-a", self.app_bundle], env=env, check=True)

        # control server publishes its discovery file inside our isolated HOME
        disc = os.path.join(cfg_dir, "agent-control.json")
        wait.wait_until(lambda: os.path.exists(disc), timeout=15, interval=0.2)
        # `open` does not return the app pid; resolve it as the newly-appeared
        # WispTerm process (used for activation, menu AX, and teardown).
        self.pid = wait.wait_until(lambda: self._new_pid(before), timeout=15, interval=0.2)
        wait.wait_until(self._has_terminal_surface, timeout=15, interval=0.2)
        self.focus()

    def _has_terminal_surface(self) -> bool:
        try:
            primary_pane_id(self.ctl.panes())
            return True
        except Exception:
            return False

    def quit(self) -> None:
        import shutil
        if self.pid is not None:
            try:
                os.kill(self.pid, signal.SIGTERM)
            except ProcessLookupError:
                self.pid = None
        if self.pid is not None:
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline:
                try:
                    os.kill(self.pid, 0)  # probe liveness
                except ProcessLookupError:
                    break
                time.sleep(0.1)
            else:
                try:
                    os.kill(self.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
        shutil.rmtree(self.home, ignore_errors=True)

    def focus(self) -> None:
        osascript.run(osascript.activate_script(self.pid))
        time.sleep(0.3)  # let activation settle before posting events

    # ---- discovery ----
    def primary_pane(self) -> str:
        return primary_pane_id(self.ctl.panes())

    # ---- real input ----
    def key(self, key_name: str, *mods: str) -> None:
        for m in mods:
            if m not in keycodes.MODIFIERS:
                raise ValueError(f"unknown modifier: {m}")
        quartz_input.key(keycodes.keycode(key_name), quartz_input.mods_to_flags(list(mods)))

    def text(self, s: str) -> None:
        for ch in s:
            if ch in ("\n", "\r"):
                self.key("return")
            else:
                quartz_input.type_char(ch)

    def click(self, x: int, y: int, *, count: int = 1) -> None:
        quartz_input.click(x, y, count=count)

    # ---- menu / window ----
    def menu_click(self, *path: str) -> None:
        osascript.run(osascript.menu_click_script(self.pid, list(path)))

    def menu_item_state(self, *path: str) -> ItemState:
        out = osascript.run(osascript.menu_item_enabled_script(self.pid, list(path)))
        return ItemState(enabled=(out.strip().lower() == "true"))

    def window_attr(self, name: str) -> str:
        return osascript.run(osascript.window_attr_script(self.pid, name))

    # ---- terminal text ----
    def get_text(self, pane: str, recent=None) -> str:
        return self.ctl.get_text(pane, recent)

    def wait_for(self, pane: str, pattern: str, timeout: float = 5.0) -> None:
        self.ctl.wait_for(pane, pattern, timeout=timeout)

    def read_clipboard(self) -> str:
        return osascript.run(osascript.clipboard_script())
