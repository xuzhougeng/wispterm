import pytest
from tests.macos_e2e.driver.wait import wait_until, matches, TimeoutError as WaitTimeout


def test_matches_substring():
    assert matches("hello world", "lo wo")
    assert not matches("hello", "xyz")
    assert matches("anything", "")  # empty needle always matches


def test_wait_until_returns_when_predicate_true():
    calls = {"n": 0}

    def pred():
        calls["n"] += 1
        return calls["n"] >= 3

    fake = _FakeClock()
    wait_until(pred, timeout=10, interval=1, clock=fake)
    assert calls["n"] == 3


def test_wait_until_raises_on_timeout():
    fake = _FakeClock()
    with pytest.raises(WaitTimeout):
        wait_until(lambda: False, timeout=2, interval=1, clock=fake)


class _FakeClock:
    def __init__(self):
        self.t = 0.0

    def monotonic(self):
        return self.t

    def sleep(self, s):
        self.t += s
