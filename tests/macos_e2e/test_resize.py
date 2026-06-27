"""Resizing the window re-sizes the PTY (TIOCSWINSZ + SIGWINCH reaches the shell).

The #171 redraw bugs lived on the resize path; this asserts the load-bearing half
of it — that a window resize actually propagates new dimensions to the child PTY,
which `stty size` (run inside the shell) reports back. It checks the dimensions
*changed*, not exact cells: cell metrics depend on font/DPI, but "resize the
window -> the shell sees a different size" is the invariant that matters.

The shell is session-scoped, so the window is restored to its original size.
"""
import re
import sys
import time

import pytest

from tests.macos_e2e.driver import osascript, wait

pytestmark = pytest.mark.skipif(sys.platform != "darwin", reason="macOS-only E2E harness")


def _window_size(app) -> tuple:
    """Current (w, h). `as string` joins a list with no separator, so the script
    must delimit the items itself ({1006,639} -> "1006639" otherwise)."""
    out = osascript.run(
        'tell application "System Events"\n'
        f'  tell (first process whose unix id is {app.pid})\n'
        '    set v to size of window 1\n'
        '    return ((item 1 of v) as string) & "," & ((item 2 of v) as string)\n'
        '  end tell\n'
        'end tell'
    )
    w, h = (int(n) for n in out.split(","))
    return w, h


def _set_size(app, w: int, h: int) -> None:
    osascript.run(
        'tell application "System Events"\n'
        f'  tell (first process whose unix id is {app.pid})\n'
        f'    set size of window 1 to {{{w}, {h}}}\n'
        '  end tell\n'
        'end tell'
    )


def _pty_size(app, pane: str, tag: str) -> tuple:
    """Run `stty size` in the shell and read back (rows, cols). A unique tag in the
    marker means the regex matches only THIS call's output, never stale scrollback
    or the echoed command line. Aborts any partial prompt line first."""
    app.send_text("\x03", pane)
    time.sleep(0.2)
    # The marker is built by the shell from two literals so the typed command line
    # ("...W''SZ...") can't itself match the assembled "WSZ<tag> R C" output.
    app.send_text(f"echo W''SZ{tag} $(stty size)\n", pane)

    pat = re.compile(rf"WSZ{tag} (\d+) (\d+)")

    def check():
        m = pat.search(app.get_text(pane))
        return (int(m.group(1)), int(m.group(2))) if m else None

    return wait.wait_until(check, timeout=8, interval=0.2)


@pytest.mark.e2e
@pytest.mark.macos_only
def test_window_resize_propagates_to_pty(app, pane):
    w0, h0 = _window_size(app)

    before = _pty_size(app, pane, "A")
    try:
        _set_size(app, w0 - 160, h0 - 120)
        time.sleep(0.5)  # let AppKit resize -> surface reflow -> SIGWINCH settle
        after = _pty_size(app, pane, "B")
        assert after != before, f"PTY size unchanged after window resize: {before} -> {after}"
    finally:
        _set_size(app, w0, h0)
