"""macOS virtual keycodes for keys used in shortcuts. Pure data — unit-tested.

Arbitrary text is typed via Unicode events (see quartz_input.type_char), so this
table only needs the named keys and letters that appear in keyboard SHORTCUTS.
Extend as new shortcut tests need more keys.
"""

_KEYCODES = {
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7,
    "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
    "t": 17, "n": 45,
    "return": 36, "tab": 48, "space": 49, "delete": 51, "escape": 53,
    "left": 123, "right": 124, "down": 125, "up": 126,
    "f1": 122, "f2": 120, "f3": 99, "f4": 118,
}

MODIFIERS = {"cmd", "shift", "ctrl", "alt"}


def keycode(name: str) -> int:
    try:
        return _KEYCODES[name.lower()]
    except KeyError:
        raise KeyError(f"unknown key name: {name!r}")
