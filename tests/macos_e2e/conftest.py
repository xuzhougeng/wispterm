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


@pytest.fixture(scope="session")
def app():
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
