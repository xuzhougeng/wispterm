"""OSC window-title escape -> surface title, asserted through the control channel.

A program inside the terminal sets its title with `ESC ] 0 ; <text> BEL`; the app
parses that PTY output (Surface.scanForOscTitle -> updateTitle) and exposes it as
the focused surface's `title` in `panes()`. This walks the whole chain (program ->
PTY -> terminal parser -> control_api title serialization), a path `panes()`
carried but no test asserted.

The escape bytes live in an on-disk script (like test_shift_enter's probe), not in
the command line: `wisptermctl send-text` decodes only `\\xNN` (not octal) and a
raw ESC injected at the prompt is swallowed by the shell's line editor, so neither
survives the input path. Run by an ASCII command, the script emits the bytes to
PTY *output* where the terminal parses them. `sleep` holds the shell off the next
prompt so macOS /etc/zshrc's precmd can't reset the title before the (throttled)
panes snapshot reflects it.
"""
import os
import sys
import time

import pytest

from tests.macos_e2e.driver import wait

pytestmark = pytest.mark.skipif(sys.platform != "darwin", reason="macOS-only E2E harness")

_MARKER = "PHANTTY_E2E_TITLE"
_SCRIPT = (
    "import sys, time\n"
    f'sys.stdout.write("\\x1b]0;{_MARKER}\\x07")\n'
    "sys.stdout.flush()\n"
    "time.sleep(4)\n"
)


def _focused_title(app, pane: str) -> str:
    for tab in app.ctl.panes().get("tabs", []):
        for s in tab.get("surfaces", []):
            if s.get("id") == pane:
                return s.get("title", "")
    return ""


@pytest.mark.e2e
@pytest.mark.macos_only
def test_osc_title_sets_surface_title(app, pane):
    script_path = os.path.join(app.home, "osc_title_probe.py")
    with open(script_path, "w") as f:
        f.write(_SCRIPT)

    # The `app` fixture is session-scoped: earlier real-keyboard tests can leave a
    # partial command on this shell's prompt line. Ctrl-C aborts it so our command
    # runs from a clean prompt rather than getting concatenated onto stray input.
    app.send_text("\x03", pane)
    time.sleep(0.3)
    app.send_text("/usr/bin/python3 ~/osc_title_probe.py\n", pane)

    box = {}

    def check():
        box["last"] = _focused_title(app, pane)
        return True if _MARKER in box["last"] else None

    try:
        wait.wait_until(check, timeout=8.0, interval=0.2)
    except wait.TimeoutError:
        raise AssertionError(f"OSC title not reflected in panes; last title={box.get('last')!r}")
