"""AppleScript builders (pure, unit-tested) + a thin osascript runner.

All process references target a PID via `first process whose unix id is <pid>`
so the harness never confuses the test instance with the developer's running
WispTerm. Menu paths are 2-level (top-level menu, item); the top-level menu name
is assumed to equal its menu bar item name (true for WispTerm's menus). Deeper
nesting is out of scope for v1.
"""
import subprocess


def _proc(pid: int) -> str:
    return f'(first process whose unix id is {pid})'


def activate_script(pid: int) -> str:
    return (
        'tell application "System Events"\n'
        f'  set frontmost of {_proc(pid)} to true\n'
        'end tell'
    )


def _menu_item_ref(path) -> str:
    top, item = path[0], path[1]
    return (
        f'menu item "{item}" of menu "{top}" '
        f'of menu bar item "{top}" of menu bar 1'
    )


def menu_click_script(pid: int, path) -> str:
    return (
        'tell application "System Events"\n'
        f'  tell {_proc(pid)}\n'
        f'    click {_menu_item_ref(path)}\n'
        '  end tell\n'
        'end tell'
    )


def menu_item_enabled_script(pid: int, path) -> str:
    return (
        'tell application "System Events"\n'
        f'  tell {_proc(pid)}\n'
        f'    return (enabled of {_menu_item_ref(path)}) as string\n'
        '  end tell\n'
        'end tell'
    )


def window_attr_script(pid: int, attr: str) -> str:
    return (
        'tell application "System Events"\n'
        f'  tell {_proc(pid)}\n'
        f'    return ({attr} of window 1) as string\n'
        '  end tell\n'
        'end tell'
    )


def clipboard_script() -> str:
    return 'the clipboard as text'


def run(script: str, timeout: float = 5.0) -> str:
    """Run an AppleScript via osascript, return trimmed stdout. Raises on error."""
    proc = subprocess.run(
        ["/usr/bin/osascript", "-e", script],
        capture_output=True, text=True, timeout=timeout,
    )
    if proc.returncode != 0:
        raise RuntimeError(f"osascript failed: {proc.stderr.strip()}\n--- script ---\n{script}")
    return proc.stdout.strip()
