import pytest
from tests.macos_e2e.driver.keycodes import keycode, MODIFIERS


def test_letters_and_named_keys():
    assert keycode("a") == 0
    assert keycode("c") == 8
    assert keycode("return") == 36
    assert keycode("escape") == 53
    assert keycode("up") == 126


def test_case_insensitive():
    assert keycode("C") == keycode("c")
    assert keycode("Return") == 36


def test_unknown_raises():
    with pytest.raises(KeyError):
        keycode("nope")


def test_modifiers_set():
    assert MODIFIERS == {"cmd", "shift", "ctrl", "alt"}
