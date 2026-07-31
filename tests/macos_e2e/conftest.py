import pytest


def pytest_configure(config):
    config.addinivalue_line("markers", "e2e: end-to-end test requiring a real WispTerm.app GUI instance")
    config.addinivalue_line("markers", "macos_only: test that only applies to the macOS backend")


# macos_only 标记的便捷别名,供用例 @macos_only 使用
import sys

macos_only = pytest.mark.skipif(sys.platform != "darwin", reason="macOS-only behavior")

import os

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
APP_BUNDLE = os.path.join(REPO_ROOT, "zig-out", "bin", "WispTerm.app")
CTL_BINARY = os.path.join(REPO_ROOT, "zig-out", "bin", "wisptermctl")


def _pyobjc_available() -> bool:
    try:
        import Quartz  # noqa: F401
        import ApplicationServices  # noqa: F401
        return True
    except Exception:
        return False


def _accessibility_trusted() -> bool:
    try:
        import ApplicationServices
        return bool(ApplicationServices.AXIsProcessTrusted())
    except Exception:
        return False


def _screen_locked() -> bool:
    # Synthetic CGEvents (keyboard/mouse) are silently dropped by WindowServer
    # while the screen is locked, so a locked session must skip rather than
    # produce a confusing "OS keyboard input path never became ready" failure
    # deep inside MacDriver.ensure_keyboard_ready. Best-effort: treat any
    # inspection failure as "not locked" (fail open) rather than skip tests
    # that could otherwise run.
    try:
        import Quartz
        info = Quartz.CGSessionCopyCurrentDictionary()
        return bool(info and info.get("CGSSessionScreenIsLocked"))
    except Exception:
        return False


def require_macos_gui():
    """Skip the calling test unless this host can drive a real WispTerm.app via
    synthetic input: macOS + importable PyObjC + a built app/ctl bundle + granted
    Accessibility permission + an unlocked screen. Fixtures that build their own
    MacDriver (instead of using the `app` fixture) must call this so they skip —
    rather than fail — when those preconditions are absent."""
    if sys.platform != "darwin":
        pytest.skip("macOS-only E2E harness")
    if not _pyobjc_available():
        pytest.skip(
            "PyObjC not importable on this interpreter. Run via /usr/bin/python3 and "
            "install the frameworks: `/usr/bin/python3 -m pip install --user "
            "pyobjc-framework-Quartz pyobjc-framework-Cocoa`."
        )
    if not os.path.exists(os.path.join(APP_BUNDLE, "Contents", "MacOS", "WispTerm")):
        pytest.skip(f"missing {APP_BUNDLE}; run `make test-macos-e2e` (builds it first)")
    if not os.path.exists(CTL_BINARY):
        pytest.skip(f"missing {CTL_BINARY}; run `make test-macos-e2e` (builds it first)")
    if not _accessibility_trusted():
        pytest.skip(
            "Accessibility permission required: grant the terminal running pytest under "
            "System Settings → Privacy & Security → Accessibility, then retry."
        )
    if _screen_locked():
        pytest.skip("screen is locked: synthetic CGEvents are dropped while locked; unlock and retry")


@pytest.fixture(scope="session")
def app():
    require_macos_gui()

    from tests.macos_e2e.driver.macos import MacDriver
    driver = MacDriver(app_bundle=APP_BUNDLE, ctl_binary=CTL_BINARY)
    driver.launch()
    yield driver
    driver.quit()


@pytest.fixture()
def pane(app):
    """Per-test convenience: focus + return the active surface id."""
    app.focus()
    return app.primary_pane()


# ---- failure diagnostics --------------------------------------------------
import json
import re

ARTIFACTS_DIR = os.path.join(os.path.dirname(__file__), "_artifacts")


@pytest.hookimpl(hookwrapper=True)
def pytest_runtest_makereport(item, call):
    """On a GUI test's failure, dump the oracles that explain *why* — panes
    topology, terminal text, window geometry, overlay ui-state, and a screenshot
    — so a red run is diagnosable without re-running locally. Best-effort: a
    dump that itself fails never overrides the real test failure."""
    outcome = yield
    rep = outcome.get_result()
    if rep.when != "call" or not rep.failed:
        return
    app = getattr(item, "funcargs", {}).get("app")
    if app is None:
        return  # not a GUI test (no `app` fixture) — nothing to dump
    _dump_failure_artifacts(item, app)


def _dump_failure_artifacts(item, app):
    out_dir = os.path.join(ARTIFACTS_DIR, re.sub(r"[^A-Za-z0-9_.-]", "_", item.nodeid))
    os.makedirs(out_dir, exist_ok=True)
    written = []

    def _try(name, fn):
        try:
            fn(os.path.join(out_dir, name))
            written.append(name)
        except Exception as e:
            with open(os.path.join(out_dir, name + ".error"), "w") as f:
                f.write(repr(e))

    def _json(path, obj):
        with open(path, "w") as f:
            json.dump(obj, f, indent=2, ensure_ascii=False)

    def _text(path, s):
        with open(path, "w") as f:
            f.write(s)

    _try("panes.json", lambda p: _json(p, app.ctl.panes()))
    _try("ui-state.json", lambda p: _json(p, app.ui_state()))
    try:
        pane = app.primary_pane()
    except Exception:
        pane = None
    if pane:
        _try("text.txt", lambda p: _text(p, app.get_text(pane)))
    _try("window.txt", lambda p: _text(
        p, "".join(f"{a}={app.window_attr(a)}\n" for a in ("size", "position"))))

    def _shot(p):
        if not app.screenshot(p):
            raise RuntimeError("screencapture unavailable (Screen Recording permission?)")
    _try("screen.png", _shot)

    print(f"\n[e2e] failure artifacts for {item.nodeid} -> {out_dir} ({', '.join(written) or 'none'})")
