"""#302 acceptance: a real Shift+Enter keystroke must reach a full-screen TUI as
the Kitty keyboard sequence ``CSI 13 ; 2 u`` (so it means "insert newline"),
distinct from a bare Enter's ``\\r`` ("submit").

This drives the whole chain through the real GUI: CGEvent keystroke -> AppKit ->
input.zig encoder -> Surface -> PTY, and -- because the probe first *queries*
Kitty support -- it also exercises the terminal's query response (``effects.
write_pty``) that lets the app turn the protocol on in the first place. Both
halves of the fix are asserted; a regression in either fails the test instead of
hanging (the raw-mode reads are guarded by ``select``).
"""
import os
import sys

import pytest

pytestmark = pytest.mark.skipif(sys.platform != "darwin", reason="macOS-only E2E harness")

# A raw-mode probe run inside the terminal's shell. It (1) queries Kitty keyboard
# support and captures the reply, (2) enables the protocol, (3) signals the test
# to press the key, then (4) dumps the next key's exact bytes. Output is hex so it
# survives screen scraping with no control characters to confuse the matcher.
_PROBE = r'''
import os, sys, termios, tty, select
fd = sys.stdin.fileno()
old = termios.tcgetattr(fd)

def read(timeout):
    r, _, _ = select.select([fd], [], [], timeout)
    return os.read(fd, 64) if r else b""

try:
    tty.setraw(fd)
    os.write(1, b"\x1b[?u")           # query Kitty keyboard flags
    qresp = read(5)                   # terminal must answer "CSI ? <flags> u"
    os.write(1, b"\x1b[>1u")          # push the "disambiguate" flag
    os.write(1, b"KITTYREADY\r\n")    # tell the test to press the key now
    keybytes = read(10)              # capture the next keystroke's encoding
finally:
    termios.tcsetattr(fd, termios.TCSADRAIN, old)
    os.write(1, b"\x1b[<u")           # pop the flag, leave the terminal clean
os.write(1, b"QRESP=" + qresp.hex().encode()
         + b" KEYBYTES=" + keybytes.hex().encode() + b"\r\n")
'''

# Shift+Enter under the protocol encodes as CSI 13 ; 2 u (Enter keycode 13,
# Shift modifier 2), NOT a bare CR.
_SHIFT_ENTER = b"\x1b[13;2u".hex()  # "1b5b31333b3275"
# A Kitty keyboard query reply is "CSI ? <flags> u"; its "\x1b[?" prefix is enough
# to prove the terminal answered the probe rather than staying silent.
_QUERY_REPLY_PREFIX = b"\x1b[?".hex()  # "1b5b3f"


@pytest.mark.e2e
@pytest.mark.macos_only
def test_shift_enter_sends_kitty_csi_u(app, pane):
    app.ensure_keyboard_ready(pane)

    probe_path = os.path.join(app.home, "kitty_shift_enter_probe.py")
    with open(probe_path, "w") as f:
        f.write(_PROBE)

    # Run the probe and wait until it has answered the query, enabled the
    # protocol, and is blocked reading the next key.
    app.text("/usr/bin/python3 ~/kitty_shift_enter_probe.py")
    app.key("return")
    app.wait_for(pane, "KITTYREADY", timeout=15)

    # The behavior under test: a single real Shift+Enter keystroke.
    app.key("return", "shift")

    app.wait_for(pane, f"KEYBYTES={_SHIFT_ENTER}", timeout=15)

    # Same line also proves the query round-trip (Part A): without a write_pty
    # reply the app could never have learned the protocol was supported.
    screen = app.get_text(pane)
    assert f"QRESP={_QUERY_REPLY_PREFIX}" in screen, (
        f"terminal did not answer the Kitty keyboard query; screen:\n{screen}"
    )
