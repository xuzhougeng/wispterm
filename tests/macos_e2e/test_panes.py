import pytest
from tests.macos_e2e.driver.panes import primary_pane_id


def _panes(active_tab, tabs):
    return {"activeTab": active_tab, "tabs": tabs}


def test_returns_focused_surface_of_active_tab():
    p = _panes(1, [
        {"index": 0, "kind": "terminal", "focusedSurfaceId": "aaa", "surfaces": [{"id": "aaa", "focused": True}]},
        {"index": 1, "kind": "terminal", "focusedSurfaceId": "bbb", "surfaces": [{"id": "bbb", "focused": True}]},
    ])
    assert primary_pane_id(p) == "bbb"


def test_single_tab():
    p = _panes(0, [{"index": 0, "kind": "terminal", "focusedSurfaceId": "only", "surfaces": [{"id": "only", "focused": True}]}])
    assert primary_pane_id(p) == "only"


def test_falls_back_to_first_focused_surface_when_focusedSurfaceId_blank():
    p = _panes(0, [{"index": 0, "kind": "terminal", "focusedSurfaceId": "", "surfaces": [
        {"id": "x", "focused": False}, {"id": "y", "focused": True}]}])
    assert primary_pane_id(p) == "y"


def test_raises_when_no_terminal_surface():
    p = _panes(0, [{"index": 0, "kind": "ai_chat", "surfaces": []}])
    with pytest.raises(LookupError):
        primary_pane_id(p)
