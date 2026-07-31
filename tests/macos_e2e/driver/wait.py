"""Pure polling/retry helpers. Clock is injectable so logic is unit-testable."""
import time


class TimeoutError(Exception):
    pass


class _RealClock:
    monotonic = staticmethod(time.monotonic)
    sleep = staticmethod(time.sleep)


def matches(haystack: str, needle: str) -> bool:
    return needle in haystack


def wait_until(predicate, timeout: float, interval: float = 0.1, clock=_RealClock):
    """Call ``predicate`` until it returns truthy or ``timeout`` seconds elapse.

    Returns the predicate's truthy value. Raises TimeoutError on timeout.
    """
    deadline = clock.monotonic() + timeout
    while True:
        value = predicate()
        if value:
            return value
        if clock.monotonic() >= deadline:
            raise TimeoutError(f"condition not met within {timeout}s")
        clock.sleep(interval)
