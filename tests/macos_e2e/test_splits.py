"""Split a pane with a real keystroke; `panes()` sees the new surface.

The split sibling of test_tabs: tab topology was the cross-tab axis, this is the
within-tab one. `Cmd+Shift+=` (split_right; macOS remaps the ctrl+shift+plus
default, and the OS turns the "=" key + Shift into "+", which the app maps to
Key.plus) adds a surface to the active tab via AppWindow.splitFocused. Until
synthetic input reached the app this could only be asserted as a static mocked
shape (test_panes); here a real key drives the change.

Self-restoring: the `app` fixture is session-scoped, so the new split is closed
(Cmd+Shift+W -> confirm overlay -> Enter, like test_tabs) to leave one surface.
"""
import sys
import time

import pytest

from tests.macos_e2e.driver import wait

pytestmark = pytest.mark.skipif(sys.platform != "darwin", reason="macOS-only E2E harness")


def _active_surface_count(app) -> int:
    panes = app.ctl.panes()
    tabs = panes.get("tabs", [])
    active = panes.get("activeTab", 0)
    tab = next((t for t in tabs if t.get("index") == active and t.get("surfaces")), None)
    if tab is None:
        tab = next((t for t in tabs if t.get("surfaces")), None)
    return len(tab.get("surfaces", [])) if tab else 0


def _wait_surfaces(app, n: int, timeout: float = 6.0):
    box = {}

    def check():
        box["last"] = _active_surface_count(app)
        return True if box["last"] == n else None

    try:
        wait.wait_until(check, timeout=timeout, interval=0.15)
    except wait.TimeoutError:
        raise AssertionError(f"expected {n} surfaces in active tab, last saw {box.get('last')}")


@pytest.mark.e2e
@pytest.mark.macos_only
def test_split_adds_surface_to_active_tab(app, pane):
    app.focus()
    app.ensure_keyboard_ready(pane)
    app.key("escape")  # dismiss any startup overlay
    base = _active_surface_count(app)

    # Cmd+Shift+= -> split_right: a second surface joins the active tab.
    app.key("equal", "cmd", "shift")
    _wait_surfaces(app, base + 1)

    # Cleanup: closing a focused terminal split is confirm-guarded; Enter accepts.
    app.key("w", "cmd", "shift")
    time.sleep(0.3)
    app.key("return")
    _wait_surfaces(app, base)
