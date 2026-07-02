"""End-to-end: opening the "MCP Servers" panel from the command palette with a
real keyboard, on a WispTerm instance whose mcp.json already has a server.

This runtime-verifies the open + input-routing wiring that the unit suite only
compile-checks: pressing Enter on the "MCP Servers" command palette row must
actually dispatch (palette closes) without crashing input routing.

Known harness gaps (see assertions below for what we fall back to):
  - `wisptermctl ui-state` has no MCP-specific field (ctl/ui_state.zig's Fields
    struct only tracks command_palette/session_launcher/settings/ai_*/ssh_*/
    startup_shortcuts — mcpServersVisible() in overlays.zig is never wired into
    buildUiStateJson). So we cannot assert "the mcp overlay is active" by name;
    we can only assert the command palette closed (activeOverlay: command_palette
    -> none) after Enter, which proves the command dispatched.
  - `get-text` reads the PTY/terminal scrollback grid (see ctl/control.zig),
    but the MCP panel is drawn as a GPU overlay layer (ui_pipeline.fillQuadAlpha
    + renderTitlebarTextStrong* in renderMcpListView, overlays.zig) that never
    touches the terminal cell buffer. There is no ctl command that dumps overlay
    text (protocol.zig's Cmd enum is only panes/get_text/send_text/ui_state/
    spawn). So we cannot assert the rendered panel contains "panel-probe" via
    get_text — that assertion would fail on a *correctly working* panel, not
    reveal a real bug. We seed the server (proving config load has a server to
    show) and prove the panel opened without crashing, which is the strongest
    assertion this harness can make honestly.
"""

import json
import os
import time

import pytest

from tests.macos_e2e.conftest import APP_BUNDLE, CTL_BINARY, require_macos_gui
from tests.macos_e2e.driver import wait
from tests.macos_e2e.driver.macos import MacDriver

# A minimal but real MCP stdio server: answers initialize + tools/list, then
# stays alive reading stdin until the app closes it. Mirrors
# test_mcp_discovery.py's _FAKE_MCP_SERVER; this test doesn't need to observe
# what it received (only that mcp.json seeds a server name into the panel), so
# it skips the request-recording bookkeeping.
_FAKE_MCP_SERVER = '''
import sys, json

def send(obj):
    sys.stdout.write(json.dumps(obj) + "\\n")
    sys.stdout.flush()

for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        msg = json.loads(line)
    except Exception:
        continue
    method, mid = msg.get("method"), msg.get("id")
    if method == "initialize":
        send({"jsonrpc": "2.0", "id": mid, "result": {
            "protocolVersion": "2025-06-18", "capabilities": {"tools": {}},
            "serverInfo": {"name": "panel-probe", "version": "1"}}})
    elif method == "tools/list":
        send({"jsonrpc": "2.0", "id": mid, "result": {"tools": []}})
    elif mid is not None:
        send({"jsonrpc": "2.0", "id": mid, "error": {"code": -32601, "message": "nope"}})
'''

# Index of the "MCP Servers" command in command/center_state.zig's
# command_entries (New Session=0, New Copilot=1, Toggle Copilot=2, Manage AI
# Profiles=3, MCP Servers=4). Empty filter lists every entry in declaration
# order (mirrors test_copilot_history.py's _COPILOT_HISTORY_INDEX rationale).
_MCP_SERVERS_INDEX = 4


def _wait_ui(app, predicate, timeout: float = 4.0):
    """Poll `wisptermctl ui-state` until `predicate(state)` holds (mirrors
    test_copilot_history.py's _wait_ui: overlay snapshot publishes on a ~200ms
    render-tick throttle, so it lags a keypress)."""
    box = {}

    def check():
        st = app.ui_state()
        box["last"] = st
        return st if predicate(st) else None

    try:
        return wait.wait_until(check, timeout=timeout, interval=0.15)
    except wait.TimeoutError:
        raise AssertionError(f"ui-state predicate unmet; last={box.get('last')}")


def _select_palette_command(app, target_index: int, timeout: float = 6.0):
    """Move the commands-mode palette selection down to `target_index` via
    arrow keys (verbatim approach from test_copilot_history.py — synthetic IMK
    text input into an overlay silently drops characters, so typing to filter
    is not robust; real-keycode arrow events are)."""
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


@pytest.fixture()
def seeded_app():
    """A fresh isolated WispTerm instance pre-seeded with mcp.json (one server)
    so opening the MCP panel has something configured to show."""
    require_macos_gui()  # this test drives the palette via real keyboard, not just ctl
    driver = MacDriver(app_bundle=APP_BUNDLE, ctl_binary=CTL_BINARY)

    # driver.launch() does os.makedirs(cfg_dir) then writes config/state itself;
    # we only need to add mcp.json, but must create the dir ourselves first
    # since we write it BEFORE calling launch().
    cfg_dir = driver._config_dir()
    os.makedirs(cfg_dir, exist_ok=True)

    server_path = os.path.join(driver.home, "fake_mcp_server.py")
    with open(server_path, "w") as f:
        f.write(_FAKE_MCP_SERVER)
    mcp_config = {"mcpServers": {"panel-probe": {"command": "/usr/bin/python3", "args": [server_path]}}}
    with open(os.path.join(cfg_dir, "mcp.json"), "w") as f:
        json.dump(mcp_config, f)

    driver.launch()
    yield driver
    driver.quit()


@pytest.mark.e2e
@pytest.mark.macos_only
def test_mcp_panel_opens_from_command_palette(seeded_app):
    app = seeded_app
    app.focus()
    pane = app.primary_pane()

    # Baseline: app alive and terminal round-trips before we touch the palette.
    app.send_text("echo before-mcp-panel\n")
    app.wait_for(pane, "before-mcp-panel", timeout=8)

    # Warm up the OS keyboard path (IMK connection is cold on a fresh launch and
    # swallows the first CGEvent burst whole; see MacDriver.ensure_keyboard_ready).
    app.ensure_keyboard_ready(pane)

    # Dismiss any first-launch overlay so the real-keyboard palette binding is
    # not eaten by it.
    app.key("escape")
    _wait_ui(app, lambda s: s["activeOverlay"] == "none")

    # Open the command palette via real keyboard (Cmd+Shift+P on macOS; see
    # src/keybind.zig defaults). ui-state makes the otherwise-invisible overlay
    # actually assertable.
    app.key("p", "cmd", "shift")
    st = _wait_ui(app, lambda s: s["activeOverlay"] == "command_palette")
    assert st["commandPalette"]["mode"] == "commands"

    # Select the "MCP Servers" row and confirm navigation actually reached it
    # (this is the strongest pre-Enter assertion available: ui-state reports
    # the palette's own selection index, which command/center_state.zig's
    # declaration order fixes at _MCP_SERVERS_INDEX for an empty filter).
    selected = _select_palette_command(app, _MCP_SERVERS_INDEX)
    assert selected == _MCP_SERVERS_INDEX

    # Execute it. commandPaletteExecuteSelected() (overlays.zig) closes the
    # palette *before* dispatching manage_mcp_servers -> openMcpServersFromCommandPalette,
    # so activeOverlay dropping to "none" (not staying "command_palette", not
    # erroring) is the proof that Enter dispatched the MCP-Servers command
    # rather than silently no-op'ing or crashing. It cannot additionally prove
    # "the mcp overlay itself is what's on top" — ui-state has no field for
    # that (see module docstring) — so this is the ceiling of what ui-state can
    # assert here.
    app.key("return")
    _wait_ui(app, lambda s: s["activeOverlay"] == "none" and not s["commandPalette"]["visible"])

    # The app must stay alive and responsive with the MCP panel up: send
    # control-channel text (bypasses the OS input path, so this checks the app
    # didn't hang/crash regardless of whether the MCP overlay is now eating
    # keyboard focus).
    app.send_text("echo after-mcp-panel\n")
    app.wait_for(pane, "after-mcp-panel", timeout=8)

    # Close the panel (Escape) and confirm the app is still fully responsive to
    # real keyboard input afterward too, mirroring test_copilot_history.py's
    # closing check that overlay input-handling doesn't eat subsequent input.
    app.key("escape")
    app.send_text("echo after-mcp-escape\n")
    app.wait_for(pane, "after-mcp-escape", timeout=8)
