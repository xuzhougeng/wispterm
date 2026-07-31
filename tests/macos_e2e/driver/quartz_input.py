"""Low-level OS input via CGEvent (Quartz). Posted to kCGHIDEventTap so events
reach the frontmost focused window — callers must focus the test window first.

- type_char: arbitrary Unicode (no keycode table needed)
- key:       named key + modifiers, by virtual keycode (for shortcuts)
- click:     mouse click at a global display point

Note on coordinates: CGEvent mouse points are in global display points. On
Retina displays the logical/point mapping can need per-display calibration; v1
smoke tests do not use click(), so no scale factor is hardcoded here.
"""
import Quartz

_TAP = Quartz.kCGHIDEventTap

_FLAGS = {
    "cmd": Quartz.kCGEventFlagMaskCommand,
    "shift": Quartz.kCGEventFlagMaskShift,
    "ctrl": Quartz.kCGEventFlagMaskControl,
    "alt": Quartz.kCGEventFlagMaskAlternate,
}


def mods_to_flags(mods) -> int:
    flags = 0
    for m in mods:
        flags |= _FLAGS[m]  # KeyError on unknown modifier
    return flags


def type_char(ch: str) -> None:
    for down in (True, False):
        ev = Quartz.CGEventCreateKeyboardEvent(None, 0, down)
        Quartz.CGEventKeyboardSetUnicodeString(ev, len(ch), ch)
        Quartz.CGEventPost(_TAP, ev)


def key(keycode: int, flags: int = 0) -> None:
    for down in (True, False):
        ev = Quartz.CGEventCreateKeyboardEvent(None, keycode, down)
        Quartz.CGEventSetFlags(ev, flags)
        Quartz.CGEventPost(_TAP, ev)


def click(x: float, y: float, count: int = 1) -> None:
    pos = Quartz.CGPointMake(x, y)
    for i in range(count):
        for etype in (Quartz.kCGEventLeftMouseDown, Quartz.kCGEventLeftMouseUp):
            ev = Quartz.CGEventCreateMouseEvent(None, etype, pos, Quartz.kCGMouseButtonLeft)
            if count > 1:
                Quartz.CGEventSetIntegerValueField(ev, Quartz.kCGMouseEventClickState, i + 1)
            Quartz.CGEventPost(_TAP, ev)
