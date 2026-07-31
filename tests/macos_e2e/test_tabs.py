"""Tab lifecycle through the real GUI — the path #279 unblocked.

`panes()` exposes tab topology but, until synthetic input reached the app, no
test could *drive* it: tabs could only be asserted as a static shape (see
test_panes' mocked JSON). This presses real keys to create and close a tab and
watches `panes()` react, which is exactly the menu/keyboard→tab-count path that
#279 reported broken.

Self-restoring: the `app` fixture is session-scoped, so the test must end on the
same tab count it started with or it pollutes every later test's `primary_pane`.
"""
import sys
import time

import pytest

from tests.macos_e2e.driver import wait

pytestmark = pytest.mark.skipif(sys.platform != "darwin", reason="macOS-only E2E harness")


def _tab_count(app) -> int:
    return len(app.ctl.panes().get("tabs", []))


def _wait_tabs(app, n: int, timeout: float = 6.0):
    """panes is published on a render-tick throttle, so a keystroke is not
    reflected instantly; poll until the count settles (or fail with the last)."""
    box = {}

    def check():
        box["last"] = _tab_count(app)
        return True if box["last"] == n else None

    try:
        wait.wait_until(check, timeout=timeout, interval=0.15)
    except wait.TimeoutError:
        raise AssertionError(f"expected {n} tabs, last saw {box.get('last')}")


def _wait_overlay(app, value: str, timeout: float = 4.0):
    box = {}

    def check():
        box["last"] = app.ui_state().get("activeOverlay")
        return True if box["last"] == value else None

    try:
        wait.wait_until(check, timeout=timeout, interval=0.15)
    except wait.TimeoutError:
        raise AssertionError(f"expected overlay {value!r}, last saw {box.get('last')!r}")


@pytest.mark.e2e
@pytest.mark.macos_only
def test_new_tab_and_close_via_keyboard(app, pane):
    app.focus()
    app.ensure_keyboard_ready(pane)

    # Clean baseline: dismiss any startup overlay, record the tab count.
    app.key("escape")
    _wait_overlay(app, "none")
    base = _tab_count(app)

    # Cmd+Shift+T opens the session launcher (default new_session; macOS remaps
    # the ctrl+shift default to cmd+shift). Its first row ("New Session",
    # pre-selected) is action new_tab — Enter creates a plain terminal tab.
    app.key("t", "cmd", "shift")
    _wait_overlay(app, "session_launcher")
    app.key("return")
    _wait_tabs(app, base + 1)

    # Cleanup: closing a focused terminal tab is guarded by a confirm overlay
    # (close_confirm.decideClose -> .confirm_terminal); Enter accepts it.
    app.key("w", "cmd", "shift")
    time.sleep(0.3)  # let the confirm overlay come up before accepting
    app.key("return")
    _wait_tabs(app, base)
