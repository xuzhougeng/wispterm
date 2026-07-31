"""A real left-click inside the terminal viewport reaches the PTY as a mouse report.

The click analog of test_shift_enter: a probe enables xterm mouse reporting
(1000) with SGR encoding (1006), signals readiness, then blocks reading the next
bytes. A single CGEvent left-click in the terminal body must arrive as an SGR
press report (`ESC [ < ... M`), proving the synthetic click routes through
AppKit -> input.zig mouse_report -> Surface -> PTY.

Coordinate-tolerant by design: any point inside the grid produces a report, so
the target is the window's content center (below the tab bar), derived from the
window's AX position/size — no per-cell geometry needed.
"""
import os
import sys

import pytest

from tests.macos_e2e.driver import osascript

pytestmark = pytest.mark.skipif(sys.platform != "darwin", reason="macOS-only E2E harness")

_PROBE = r'''
import os, sys, termios, tty, select
fd = sys.stdin.fileno()
old = termios.tcgetattr(fd)
try:
    tty.setraw(fd)
    os.write(1, b"\x1b[?1000h\x1b[?1006h")   # enable mouse tracking + SGR encoding
    os.write(1, b"MOUSEREADY\r\n")
    r, _, _ = select.select([fd], [], [], 10)
    data = os.read(fd, 64) if r else b""
finally:
    os.write(1, b"\x1b[?1006l\x1b[?1000l")    # disable, leave the terminal clean
    termios.tcsetattr(fd, termios.TCSADRAIN, old)
os.write(1, b"MOUSE=" + data.hex().encode() + b"\r\n")
'''

# An SGR mouse report opens with "ESC [ <" — its hex prefix proves the click
# reached the surface as a report rather than being dropped or echoed as text.
_SGR_PREFIX = b"\x1b[<".hex()  # "1b5b3c"


def _win_pair(app, prop):
    """Read a 2-element window property (size/position) as (a, b). `as string`
    concatenates the list with no separator ({1006,639} -> "1006639"), so the
    script must join the items explicitly."""
    out = osascript.run(
        'tell application "System Events"\n'
        f'  tell (first process whose unix id is {app.pid})\n'
        f'    set v to {prop} of window 1\n'
        '    return ((item 1 of v) as string) & "," & ((item 2 of v) as string)\n'
        '  end tell\n'
        'end tell'
    )
    a, b = (int(n) for n in out.split(","))
    return a, b


def _window_rect(app):
    """(x, y, w, h) of the test window in screen points (AX == CGEvent space)."""
    px, py = _win_pair(app, "position")
    w, h = _win_pair(app, "size")
    return px, py, w, h


@pytest.mark.e2e
@pytest.mark.macos_only
def test_left_click_reaches_pty_as_mouse_report(app, pane):
    app.focus()
    app.ensure_keyboard_ready(pane)
    app.send_text("\x03", pane)  # clean prompt before launching the probe

    probe_path = os.path.join(app.home, "mouse_probe.py")
    with open(probe_path, "w") as f:
        f.write(_PROBE)

    app.send_text("/usr/bin/python3 ~/mouse_probe.py\n", pane)
    app.wait_for(pane, "MOUSEREADY", timeout=15)

    # Click the content center — safely below the tab bar, inside the grid.
    x, y, w, h = _window_rect(app)
    app.click(x + w // 2, y + int(h * 0.6))

    app.wait_for(pane, f"MOUSE={_SGR_PREFIX}", timeout=15)
