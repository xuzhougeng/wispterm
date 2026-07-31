import sys
import pytest

pytestmark = pytest.mark.skipif(sys.platform != "darwin", reason="needs Quartz")


def test_mods_to_flags_combines_and_rejects_unknown():
    import Quartz
    from tests.macos_e2e.driver.quartz_input import mods_to_flags

    assert mods_to_flags([]) == 0
    assert mods_to_flags(["cmd"]) == Quartz.kCGEventFlagMaskCommand
    combo = mods_to_flags(["cmd", "shift"])
    assert combo == (Quartz.kCGEventFlagMaskCommand | Quartz.kCGEventFlagMaskShift)
    with pytest.raises(KeyError):
        mods_to_flags(["hyper"])
