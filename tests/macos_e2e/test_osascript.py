from tests.macos_e2e.driver.osascript import (
    activate_script, menu_click_script, menu_item_enabled_script,
    window_attr_script,
)


def test_activate_targets_pid():
    s = activate_script(4321)
    assert "unix id is 4321" in s
    assert "frontmost" in s


def test_menu_click_two_level_path():
    s = menu_click_script(4321, ["Edit", "Copy"])
    assert 'menu item "Copy"' in s
    assert 'menu "Edit"' in s
    assert 'menu bar item "Edit"' in s
    assert "unix id is 4321" in s


def test_menu_item_enabled_returns_boolean_expr():
    s = menu_item_enabled_script(7, ["Edit", "Copy"])
    assert "enabled of" in s
    assert 'menu item "Copy"' in s


def test_window_attr_script():
    s = window_attr_script(7, "size")
    assert "size of window 1" in s
    assert "unix id is 7" in s
