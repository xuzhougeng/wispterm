"""E2E coverage for `wisptermctl ui-state` — the overlay semantic oracle.

`panes` exposes tab/split/focus topology; `ui-state` adds the overlay layer
(which modal is up, command-palette selection/filter/mode) that `get-text` and
`panes` cannot see. Before this, overlay flows could only assert "the app stays
responsive" (see test_copilot_history); now they can assert the actual state.
"""
import pytest

from tests.macos_e2e.driver import wait


def _wait_ui(app, predicate, timeout: float = 4.0):
    """Poll ui-state until `predicate(state)` holds (the snapshot is published on
    a ~200ms render-tick throttle, so a key press is not reflected instantly)."""
    box = {}

    def check():
        st = app.ui_state()
        box["last"] = st
        return st if predicate(st) else None

    try:
        return wait.wait_until(check, timeout=timeout, interval=0.15)
    except wait.TimeoutError:
        raise AssertionError(f"ui-state predicate unmet; last={box.get('last')}")


@pytest.mark.e2e
@pytest.mark.macos_only
def test_ui_state_reports_overlay_shape(app, pane):
    """Full ctl path (build -> publish -> socket -> parse) yields a well-formed
    overlay snapshot, independent of synthetic input working."""
    st = app.ui_state()
    assert "activeOverlay" in st
    cp = st["commandPalette"]
    assert set(["visible", "mode", "selected", "visibleCount", "filter"]).issubset(cp)
    assert isinstance(cp["visible"], bool)
    assert st["activeOverlay"] == "none" or isinstance(st["activeOverlay"], str)


@pytest.mark.e2e
@pytest.mark.macos_only
def test_command_palette_overlay_state_is_observable(app, pane):
    """Real keyboard drives the command palette; ui-state makes the otherwise
    invisible overlay selection/filter assertable."""
    app.focus()
    # Dismiss any startup overlay so we have a clean baseline.
    app.key("escape")
    _wait_ui(app, lambda s: s["activeOverlay"] == "none")

    # Open the command palette via real keyboard. On macOS the default binding is
    # Cmd+Shift+P (Ctrl+Shift+P elsewhere); see keybind.zig defaults.
    app.key("p", "cmd", "shift")
    st = _wait_ui(app, lambda s: s["activeOverlay"] == "command_palette")
    assert st["commandPalette"]["visible"] is True
    assert st["commandPalette"]["mode"] == "commands"
    # Unfiltered, the palette lists many commands.
    assert st["commandPalette"]["visibleCount"] >= 2

    # Arrow navigation moves the selection — invisible to get-text, visible here.
    app.key("down")
    _wait_ui(app, lambda s: s["commandPalette"]["selected"] == 1)

    # Typing filters the list; the filter text is reflected in ui-state.
    app.text("s")
    _wait_ui(app, lambda s: s["commandPalette"]["filter"] == "s")

    # Escape closes it; overlay returns to none.
    app.key("escape")
    _wait_ui(app, lambda s: s["activeOverlay"] == "none")
