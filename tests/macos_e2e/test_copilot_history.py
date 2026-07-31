import json
import os
import time

import pytest

from tests.macos_e2e.conftest import APP_BUNDLE, CTL_BINARY, require_macos_gui
from tests.macos_e2e.driver import wait
from tests.macos_e2e.driver.macos import MacDriver


def _wait_ui(app, predicate, timeout: float = 4.0):
    """Poll `wisptermctl ui-state` until `predicate(state)` holds. The overlay
    snapshot is published on a ~200ms render-tick throttle, so a key press is not
    reflected instantly (mirrors test_ui_state.py::_wait_ui)."""
    box = {}

    def check():
        st = app.ui_state()
        box["last"] = st
        return st if predicate(st) else None

    try:
        return wait.wait_until(check, timeout=timeout, interval=0.15)
    except wait.TimeoutError:
        raise AssertionError(f"ui-state predicate unmet; last={box.get('last')}")


# Index of the "Copilot History" command in command_center_state.zig's
# command_entries (New Session=0, New Copilot=1, Toggle Copilot=2, Manage AI
# Profiles=3, Copilot History=4). With an empty filter rebuildPaletteScratch lists
# every entry in declaration order (commandEntryMatches is unconditionally true),
# so the row sits at this fixed selection index. If the command list is reordered
# this constant moves with it — the mode=="history" assertion after Enter catches a
# stale value loudly.
_COPILOT_HISTORY_INDEX = 4


def _select_palette_command(app, target_index: int, timeout: float = 6.0):
    """Move the commands-mode palette selection down to `target_index`, confirming
    each step through ui-state. We navigate with arrow keys instead of typing the
    command name: synthetic IMK text input into an overlay is unreliable on macOS
    (it silently drops characters / whole bursts), whereas real-keycode arrow events
    are not. Confirm-and-retry guards against a rare dropped Down, and waiting past
    the ~200ms publish throttle before re-pressing avoids overshooting."""
    deadline = time.monotonic() + timeout
    while True:
        sel = app.ui_state()["commandPalette"]["selected"]
        if sel >= target_index:
            return sel
        app.key("down")
        try:
            _wait_ui(app, lambda s, prev=sel: s["commandPalette"]["selected"] > prev, timeout=1.0)
        except AssertionError:
            pass  # key dropped; loop re-reads and presses again
        if time.monotonic() >= deadline:
            sel = app.ui_state()["commandPalette"]["selected"]
            raise AssertionError(f"palette selection stuck at {sel}, want {target_index}")


def _session_record(session_id: str, title: str, model: str, updated_at_ms: int, copilot: bool):
    return {
        "session_id": session_id,
        "title": title,
        "base_url": "https://api.example.com",
        "api_key": "k",
        "model": model,
        "protocol": "chat_completions",
        "system_prompt": "sys",
        "thinking_enabled": False,
        "reasoning_effort": "low",
        "stream": True,
        "max_tokens": 8192,
        "agent_enabled": True,
        "vision_enabled": False,
        "copilot": copilot,
        "created_at": updated_at_ms,
        "updated_at": updated_at_ms,
        "messages": [{"role": "user", "content": f"hello from {title}"}],
    }


@pytest.fixture()
def seeded_app():
    """A fresh isolated WispTerm instance pre-seeded with copilot history sessions.

    Writing only sessions/*.json (no index.json) exercises the storage layer's
    index-rebuild path on first launch.
    """
    require_macos_gui()  # this test drives the palette via real keyboard, not just ctl
    driver = MacDriver(app_bundle=APP_BUNDLE, ctl_binary=CTL_BINARY)
    sessions_dir = os.path.join(driver._config_dir(), "agent-history", "sessions")
    os.makedirs(sessions_dir, exist_ok=True)
    now_ms = int(time.time() * 1000)
    day = 86400 * 1000
    seeds = [
        _session_record("hist-deploy", "Deploy notes", "deepseek-v4", now_ms, False),
        _session_record("hist-sidebar", "Sidebar chat", "glm-5", now_ms - day, True),
        _session_record("hist-old", "Old planning", "gpt-x", now_ms - 20 * day, False),
    ]
    for rec in seeds:
        with open(os.path.join(sessions_dir, f"{rec['session_id']}.json"), "w") as f:
            json.dump(rec, f)
    driver.launch()
    yield driver
    driver.quit()


@pytest.mark.e2e
@pytest.mark.macos_only
def test_copilot_history_input_driven(seeded_app):
    app = seeded_app
    app.focus()
    pane = app.primary_pane()

    # Baseline: app alive and terminal round-trips. (Control-channel inject works
    # regardless of any overlay, so this is independent of the keyboard path below.)
    app.send_text("echo before-history\n")
    app.wait_for(pane, "before-history", timeout=8)

    # Warm up the OS keyboard path before driving the palette with real keys: the
    # IMK connection is cold on a fresh launch and swallows the first CGEvent burst
    # whole, which would otherwise drop the Cmd+Shift+P / arrow keys below.
    app.ensure_keyboard_ready(pane)

    # Dismiss any first-launch overlay so the real-keyboard palette binding is not
    # eaten by it.
    app.key("escape")
    _wait_ui(app, lambda s: s["activeOverlay"] == "none")

    # Open the command palette via real keyboard. On macOS the default binding is
    # Cmd+Shift+P (Ctrl+Shift+P elsewhere); see src/keybind.zig defaults. ui-state
    # makes the otherwise-invisible overlay actually assertable.
    app.key("p", "cmd", "shift")
    st = _wait_ui(app, lambda s: s["activeOverlay"] == "command_palette")
    assert st["commandPalette"]["mode"] == "commands"

    # Select the "Copilot History" command (by row, see _select_palette_command) and
    # execute it to enter history mode within the palette.
    _select_palette_command(app, _COPILOT_HISTORY_INDEX)
    app.key("return")            # execute -> enters history mode (panel shows seeds)
    st = _wait_ui(app, lambda s: s["commandPalette"]["mode"] == "history")
    assert st["activeOverlay"] == "command_palette"
    source_before = st["commandPalette"]["historySource"]  # "all" on entry

    # Exercise the history-mode input handlers, then assert Tab actually cycled the
    # source filter (all -> sidebar -> tab) — invisible to get-text, visible here.
    app.key("down")              # navigate history rows (skips group headers)
    app.key("up")
    app.key("tab")               # cycle source filter: all -> sidebar
    st = _wait_ui(app, lambda s: s["commandPalette"]["historySource"] != source_before)
    assert st["commandPalette"]["historySource"] != source_before
    app.key("tab")               # -> tab

    # First escape leaves history mode (back to commands), second closes the palette.
    app.key("escape")
    _wait_ui(app, lambda s: s["commandPalette"]["mode"] == "commands")
    app.key("escape")
    _wait_ui(app, lambda s: s["activeOverlay"] == "none")

    # The whole overlay-input flow must leave the app responsive and must NOT have
    # eaten subsequent terminal input.
    app.send_text("echo after-history\n")
    app.wait_for(pane, "after-history", timeout=8)
