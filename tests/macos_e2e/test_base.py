from tests.macos_e2e.driver.base import ItemState, Driver


def test_item_state_fields():
    s = ItemState(enabled=True, checked=None)
    assert s.enabled is True
    assert s.checked is None


def test_driver_is_protocol_with_expected_methods():
    for name in ["launch", "quit", "focus", "primary_pane", "key", "text",
                 "click", "menu_click", "menu_item_state", "window_attr",
                 "get_text", "wait_for"]:
        assert hasattr(Driver, name)
