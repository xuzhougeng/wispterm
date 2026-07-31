import pytest


@pytest.mark.e2e
@pytest.mark.macos_only
def test_real_keyboard_text_reaches_pty(app, pane):
    """#279 acceptance: the real-input chain end to end — synthetic keystrokes ->
    AppKit -> input.zig -> surface -> PTY -> shell — asserted by the typed
    command's output appearing in the terminal. Unlike send-text (control
    channel), this exercises the actual OS keyboard path the #279 skip claimed was
    broken under automation."""
    app.ensure_keyboard_ready(pane)
    marker = "real-input-ok-9417"
    app.text(f"echo {marker}\n")
    app.wait_for(pane, marker, timeout=8)


@pytest.mark.e2e
@pytest.mark.macos_only
@pytest.mark.xfail(
    strict=True,
    reason=(
        "WispTerm terminals have no Cmd+A select-all (keybind.zig binds only "
        "Cmd+C=copy on macOS); copying a selection needs a mouse triple-click + "
        "click-coordinate helper not yet in the driver. NOT blocked by #279 — real "
        "key input reaches the PTY (see test_real_keyboard_text_reaches_pty). "
        "strict=True flips this to a failure if select-all/copy ever starts working."
    ),
)
def test_cmd_c_copies_selection(app, pane):
    app.ensure_keyboard_ready(pane)
    marker = "copy-me-e2e-3382"
    app.text(marker)
    app.wait_for(pane, marker, timeout=8)
    app.key("a", "cmd")   # Select All (no such binding in the terminal)
    app.key("c", "cmd")   # Copy
    assert marker in app.read_clipboard()
