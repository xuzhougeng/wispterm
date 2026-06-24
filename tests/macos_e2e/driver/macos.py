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
        self._kbd_token = 0

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
        # Pre-mark the first-run wizard as already prompted so the AI-setup form
        # does not auto-open and capture the keyboard on a fresh launch (it has no
        # AI profile). Without this the form swallows synthetic key input even after
        # the command palette is opened over it (see startup_tabs.shouldAutoShowAgentForm
        # / window_state_codec `ai-setup-prompted`). The file lives at
        # <config_dir>/state (dirs.stateFilePath); unknown keys are tolerated.
        with open(os.path.join(cfg_dir, "state"), "w") as f:
            f.write("ai-setup-prompted = 1\n")

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

    def ui_state(self) -> dict:
        # Overlay semantic state (active overlay, command-palette selection/filter).
        return self.ctl.ui_state()

    # ---- real input ----
    # Space successive keystrokes apart. Text typed through CGEvent's Unicode path
    # is delivered via the Input Method Kit; posting events back-to-back races IMK
    # ("error messaging the mach port for IMKCFRunLoopWakeUpReliable") and silently
    # drops characters, so longer strings arrive mangled or empty. A small inter-key
    # gap makes delivery reliable (40ms keeps margin for slower/CI machines).
    _KEY_GAP = 0.04

    def key(self, key_name: str, *mods: str) -> None:
        for m in mods:
            if m not in keycodes.MODIFIERS:
                raise ValueError(f"unknown modifier: {m}")
        quartz_input.key(keycodes.keycode(key_name), quartz_input.mods_to_flags(list(mods)))
        time.sleep(self._KEY_GAP)

    def text(self, s: str) -> None:
        for ch in s:
            if ch in ("\n", "\r"):
                self.key("return")
            else:
                quartz_input.type_char(ch)
                time.sleep(self._KEY_GAP)

    def ensure_keyboard_ready(self, pane: str = None, tries: int = 6) -> None:
        """Warm up the OS keyboard path and block until a keystroke demonstrably
        reaches the shell, so subsequent real-input assertions are not flaky.

        The Input Method Kit connection is cold on a fresh launch (and goes cold
        while an instance sits idle); the first CGEvent burst after that is
        swallowed whole re-establishing it (the "IMKCFRunLoopWakeUpReliable" race),
        landing nothing in the PTY. A dropped burst leaves no partial text, so
        retrying is safe. Each round uses a fresh sentinel run as a shell no-op
        (`:`), so a confirm can only succeed on the current round's keystrokes —
        never on a previous round's leftover scrollback.
        """
        pane = pane or self.primary_pane()
        for _ in range(tries):
            self._kbd_token += 1
            sentinel = f"__wisp_kbd_ready_{self._kbd_token}__"
            self.focus()
            self.text(f": {sentinel}")
            self.key("return")
            try:
                self.ctl.wait_for(pane, sentinel, timeout=1.5)
                return
            except wait.TimeoutError:
                continue
        raise AssertionError("OS keyboard input path never became ready")

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

    def send_text(self, data: str, pane: str = None) -> None:
        # Control-channel text injection (bypasses the OS input path; see #279).
        self.ctl.send_text(pane or self.primary_pane(), data)

    def wait_for(self, pane: str, pattern: str, timeout: float = 5.0) -> None:
        self.ctl.wait_for(pane, pattern, timeout=timeout)

    def read_clipboard(self) -> str:
        return osascript.run(osascript.clipboard_script())
