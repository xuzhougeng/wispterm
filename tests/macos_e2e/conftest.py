import pytest


def pytest_configure(config):
    config.addinivalue_line("markers", "e2e: end-to-end test requiring a real WispTerm.app GUI instance")
    config.addinivalue_line("markers", "macos_only: test that only applies to the macOS backend")


# macos_only 标记的便捷别名,供用例 @macos_only 使用
import sys

macos_only = pytest.mark.skipif(sys.platform != "darwin", reason="macOS-only behavior")
