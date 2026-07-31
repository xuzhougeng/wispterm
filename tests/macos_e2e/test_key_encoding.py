"""Broaden the real keyboard -> PTY coverage: assert the *exact* bytes a set of
keystrokes deliver to a full-screen TUI in LEGACY mode (no Kitty keyboard
protocol active).

This complements ``test_shift_enter.py`` (which proves Shift+Enter becomes
``CSI 13;2u`` *when the protocol is on*). The most important case here is the
mirror image, central to issue #302: with the protocol OFF, Shift+Enter is
byte-for-byte identical to a bare Enter (``\\r``) -- there is no way to
distinguish them in legacy mode, so a TUI only sees a difference once it enables
Kitty. The other cases lock down the legacy encoding of common control keys
(Ctrl+C, Tab, Escape) through the same real CGEvent -> AppKit -> input.zig ->
Surface -> PTY chain.

Each case runs a tiny raw-mode probe in the pane's shell that (1) pops any active
Kitty keyboard flags so the encoding is unambiguously legacy, (2) signals the
test to press the key, then (3) dumps the next keystroke's exact bytes as hex
(survives screen scraping; no control chars to confuse the matcher). A unique
per-case token keeps stale screen output from matching an earlier case.
"""
import os
import sys

import pytest

pytestmark = pytest.mark.skipif(sys.platform != "darwin", reason="macOS-only E2E harness")

# Raw-mode probe. argv[1] is a unique token echoed back in both the READY and the
# KB lines so each parametrized case matches only its own output.
_PROBE = r'''
import os, sys, termios, tty, select
tok = (sys.argv[1] if len(sys.argv) > 1 else "X").encode()
fd = sys.stdin.fileno()
old = termios.tcgetattr(fd)

def read(timeout):
    r, _, _ = select.select([fd], [], [], timeout)
    return os.read(fd, 64) if r else b""

try:
    tty.setraw(fd)
    os.write(1, b"\x1b[<u")              # pop Kitty keyboard flags -> legacy mode
    os.write(1, b"READY:" + tok + b"\r\n")
    keybytes = read(10)                  # capture the next keystroke's bytes
finally:
    termios.tcsetattr(fd, termios.TCSADRAIN, old)
os.write(1, b"KB:" + tok + b"=" + keybytes.hex().encode() + b"\r\n")
'''

# (id/token, app.key args, expected legacy PTY bytes)
_CASES = [
    ("plain_enter", ("return",), b"\r"),
    # #302 gating: with no Kitty protocol, Shift+Enter is indistinguishable from Enter.
    ("shift_enter_legacy", ("return", "shift"), b"\r"),
    ("ctrl_c", ("c", "ctrl"), b"\x03"),
    ("tab", ("tab",), b"\t"),
    ("escape", ("escape",), b"\x1b"),
]


@pytest.mark.e2e
@pytest.mark.macos_only
@pytest.mark.parametrize("token,keyargs,expected", _CASES, ids=[c[0] for c in _CASES])
def test_legacy_key_encoding_reaches_pty(app, pane, token, keyargs, expected):
    app.ensure_keyboard_ready(pane)

    probe_path = os.path.join(app.home, "key_encoding_probe.py")
    with open(probe_path, "w") as f:
        f.write(_PROBE)

    app.text(f"/usr/bin/python3 ~/key_encoding_probe.py {token}")
    app.key("return")
    app.wait_for(pane, f"READY:{token}", timeout=15)

    # The behavior under test: one real keystroke, its exact bytes captured.
    app.key(*keyargs)

    app.wait_for(pane, f"KB:{token}={expected.hex()}", timeout=15)
