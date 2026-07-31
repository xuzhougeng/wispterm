# macOS UI E2E 测试 harness 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 为 phantty 新增一套本地运行的 macOS GUI 端到端测试 harness:启动隔离的真实 `WispTerm.app`,用真实 OS 输入驱动,断言终端正文与窗口/菜单状态。

**Architecture:** pytest harness。纯逻辑(panes JSON 解析、keycode 映射、轮询等待)用单元测试 TDD;OS 交互(CGEvent 键鼠、osascript 菜单/AX、wisptermctl 子进程)封装进平台后端 `MacDriver`,由 3 个冒烟用例做集成验证。driver 拆成"抽象接口 + 平台后端",正文层将来 Windows 复用。

**Tech Stack:** Python 3(`/usr/bin/python3`,Xcode/CLT 自带 PyObjC:Quartz / ApplicationServices)、pytest、Zig build(`zig build macos-app` / `wisptermctl`)、AppleScript(`osascript`)。

---

## 关键事实(实施时依赖,均已核实)

- **`.app` 路径**:`zig build -Dtarget=<macos> macos-app` 装到 `zig-out/bin/WispTerm.app`;可执行文件 `zig-out/bin/WispTerm.app/Contents/MacOS/WispTerm`(`build.zig:148,161,1161`)。
- **wisptermctl**:`zig build -Dtarget=<macos> wisptermctl` 装到 `zig-out/bin/wisptermctl`(`build.zig:18-28`)。
- **默认 target 是 Windows**:`macos-app` 与 `wisptermctl` 都必须显式传 `-Dtarget=aarch64-macos`(Apple Silicon)或 `x86_64-macos`(Intel),否则编出 Windows 产物。
- **实例隔离**:覆盖 `HOME`。macOS config 目录 = `$HOME/Library/Application Support/wispterm`(`app_dir_name="wispterm"`,`dirs.zig:4,42-46`,**不读 XDG_CONFIG_HOME**)。
- **控制服务默认关闭**:`agent-control-enabled` 默认 `false`(`config.zig:391`;`App.zig:397` 未开启则 return)。测试 config **必须**写 `agent-control-enabled = true`,服务启动后才写 `agent-control.json`(端口+token,`App.zig:403-407`)。
- **wisptermctl 输出**:
  - `panes` → 打印 JSON(+换行):`{"activeTab":N,"tabs":[{"index":N,"title":"…","kind":"terminal","focusedSurfaceId":"<id>","surfaces":[{"id":"<id>","title":"…","focused":true,"cols":80,"rows":24,"cursorX":N,"cursorY":N,"cwd":"…",…}]}]}`(`AppWindow.zig:5403-5475`)。非终端 tab 的 `surfaces` 为 `[]`。
  - `get-text -t <id> [--recent N]` → 打印面板原始文本。
  - `wait-for -t <id> <pattern> [--timeout <秒>]` → 轮询直到匹配。
  - 自动发现:读 `$HOME/Library/Application Support/wispterm/agent-control.json` —— 所有调用带同一 `HOME` env 即连到测试实例。
- **config 键**:`agent-control-enabled`、`auto-update-check`(默认 true,测试设 false)、`font-size`(默认 13)、`theme`。Ghostty 风格 `key = value` 文本文件,路径 `$HOME/Library/Application Support/wispterm/config`。
- **运行解释器 = `/usr/bin/python3`(3.9,Xcode/CLT)**。它的 user-site(`~/Library/Python/3.9/.../site-packages`)挂着 `Quartz`/`ApplicationServices`/`AppKit`/`objc`(本机已 `pip install --user` 过,已验证 import 成功)——**不是系统自带**。另一个 `python3`(3.13)没有 PyObjC,**不可用**。
- **pytest 未预装**:本机两个 python 都没有 pytest。`make` 入口在缺失时自动 `/usr/bin/python3 -m pip install --user pytest`;装到 user-site 后 `/usr/bin/python3 -m pytest` 能同时看到 PyObjC 与 pytest。
- **导入路径**:用例用 `from tests.macos_e2e.driver.xxx import ...`。需 ① repo 根有 `pytest.ini`(`pythonpath = .`)② `tests/__init__.py` + 各级 `__init__.py`,从 repo 根运行 pytest 时 `tests.macos_e2e...` 才可解析。`.gitignore` 已忽略 `__pycache__`/`*.pyc`。
- **辅助功能权限**:CGEvent 注入 + System Events 控制需要运行 pytest 的终端被授予"辅助功能"权限;用 `ApplicationServices.AXIsProcessTrusted()` 预检。
- **Makefile**:recipe 用 **tab** 缩进,`.PHONY` 声明在顶部(`Makefile:1`)。

## 文件结构

```
pytest.ini               # repo 根:pythonpath = .(让 tests.* 绝对导入可解析)
tests/__init__.py        # 使 tests 成为包
tests/macos_e2e/
  __init__.py
  conftest.py            # 标记注册 + session 级 app fixture + 权限/产物预检
  driver/
    __init__.py
    base.py              # Driver Protocol + ItemState(纯接口,无 macOS 调用)
    panes.py             # 纯:primary_pane_id(panes_dict) — 单测
    keycodes.py          # 纯:keycode(name) / MODIFIERS — 单测
    wait.py              # 纯:wait_until(pred,timeout,...) / matches — 单测
    ctl.py               # wisptermctl 子进程封装(panes/get_text/wait_for)
    osascript.py         # AppleScript 字符串构造(纯,单测)+ run() 子进程
    quartz_input.py      # CGEvent 键鼠合成 + mods_to_flags
    macos.py             # MacDriver(Driver):组装以上,管 app 生命周期
  test_panes.py          # 单测
  test_keycodes.py       # 单测
  test_wait.py           # 单测
  test_osascript.py      # 单测(字符串构造)
  test_smoke.py          # e2e:echo 往返
  test_keybinds.py       # e2e:Cmd+C 复制
  test_menu.py           # e2e:Edit>Copy enabled 状态(@macos_only)
Makefile                 # 新增 test-macos-e2e target
```

约定:`make test-macos-e2e` 先按本机架构构建 `macos-app` + `wisptermctl`,再 `python3 -m pytest tests/macos_e2e`。单测无需 GUI;e2e 用例依赖 `app` fixture,权限/产物缺失时 `pytest.skip` 并给清晰指引。

---

## Task 1: 包骨架 + 标记注册 + Makefile 入口

**Files:**
- Create: `tests/__init__.py`
- Create: `tests/macos_e2e/__init__.py`
- Create: `tests/macos_e2e/driver/__init__.py`
- Create: `tests/macos_e2e/conftest.py`
- Create: `pytest.ini`(repo 根)
- Modify: `Makefile`

- [ ] **Step 1: 建包占位文件 + pytest 配置**

`tests/__init__.py`(空文件)— 让 `tests.macos_e2e...` 可被解析
`tests/macos_e2e/__init__.py`(空文件)
`tests/macos_e2e/driver/__init__.py`(空文件)

`pytest.ini`(repo 根,让 repo 根进 sys.path,使绝对导入生效):

```ini
[pytest]
pythonpath = .
```

- [ ] **Step 2: conftest 注册自定义标记**

`tests/macos_e2e/conftest.py`:

```python
import pytest


def pytest_configure(config):
    config.addinivalue_line("markers", "e2e: end-to-end test requiring a real WispTerm.app GUI instance")
    config.addinivalue_line("markers", "macos_only: test that only applies to the macOS backend")


# macos_only 标记的便捷别名,供用例 @macos_only 使用
import sys

macos_only = pytest.mark.skipif(sys.platform != "darwin", reason="macOS-only behavior")
```

- [ ] **Step 3: Makefile 增加 target(注意 recipe 用 TAB 缩进)**

把第 1 行 `.PHONY` 改成包含新 target,并在文件末尾追加:

```make
.PHONY: debug release clean update-ghostty test-macos-e2e

# ... 现有 target 不变 ...

# macOS UI 端到端测试:按本机架构构建 .app + wisptermctl,确保 pytest 在位,再跑。
# 固定用 /usr/bin/python3(其 user-site 挂着 PyObjC)。需已授予运行终端"辅助功能"权限。
MACOS_TARGET := $(shell uname -m | sed 's/arm64/aarch64/')-macos
test-macos-e2e:
	zig build -Dtarget=$(MACOS_TARGET) macos-app
	zig build -Dtarget=$(MACOS_TARGET) wisptermctl
	/usr/bin/python3 -m pytest --version >/dev/null 2>&1 || /usr/bin/python3 -m pip install --user pytest
	/usr/bin/python3 -m pytest tests/macos_e2e -v
```

- [ ] **Step 4: 确保 pytest 可用并验证能 collect**

Run:
```bash
/usr/bin/python3 -m pytest --version >/dev/null 2>&1 || /usr/bin/python3 -m pip install --user pytest
/usr/bin/python3 -m pytest tests/macos_e2e --collect-only -q
```
Expected: 退出 0,无 import/collection 错误(此时无用例,输出 "no tests ran" 或 0 collected 均可)。

- [ ] **Step 5: Commit**

```bash
git add tests/__init__.py tests/macos_e2e/__init__.py tests/macos_e2e/driver/__init__.py tests/macos_e2e/conftest.py pytest.ini Makefile
git commit -m "test(macos-e2e): scaffold harness package, markers, make target"
```

---

## Task 2: panes.py — panes JSON 解析(纯逻辑,TDD)

**Files:**
- Create: `tests/macos_e2e/driver/panes.py`
- Test: `tests/macos_e2e/test_panes.py`

- [ ] **Step 1: 写失败测试**

`tests/macos_e2e/test_panes.py`:

```python
import pytest
from tests.macos_e2e.driver.panes import primary_pane_id


def _panes(active_tab, tabs):
    return {"activeTab": active_tab, "tabs": tabs}


def test_returns_focused_surface_of_active_tab():
    p = _panes(1, [
        {"index": 0, "kind": "terminal", "focusedSurfaceId": "aaa", "surfaces": [{"id": "aaa", "focused": True}]},
        {"index": 1, "kind": "terminal", "focusedSurfaceId": "bbb", "surfaces": [{"id": "bbb", "focused": True}]},
    ])
    assert primary_pane_id(p) == "bbb"


def test_single_tab():
    p = _panes(0, [{"index": 0, "kind": "terminal", "focusedSurfaceId": "only", "surfaces": [{"id": "only", "focused": True}]}])
    assert primary_pane_id(p) == "only"


def test_falls_back_to_first_focused_surface_when_focusedSurfaceId_blank():
    p = _panes(0, [{"index": 0, "kind": "terminal", "focusedSurfaceId": "", "surfaces": [
        {"id": "x", "focused": False}, {"id": "y", "focused": True}]}])
    assert primary_pane_id(p) == "y"


def test_raises_when_no_terminal_surface():
    p = _panes(0, [{"index": 0, "kind": "ai_chat", "surfaces": []}])
    with pytest.raises(LookupError):
        primary_pane_id(p)
```

- [ ] **Step 2: 跑测试确认失败**

Run: `/usr/bin/python3 -m pytest tests/macos_e2e/test_panes.py -v`
Expected: FAIL(`ModuleNotFoundError: ... panes`)

- [ ] **Step 3: 实现**

`tests/macos_e2e/driver/panes.py`:

```python
"""Pure parsing of `wisptermctl panes` JSON. No OS dependencies — unit-tested."""


def primary_pane_id(panes: dict) -> str:
    """Return the focused surface id of the active tab.

    Resolution order: the tab whose ``index`` equals ``activeTab`` (or the first
    terminal tab if none matches) → its ``focusedSurfaceId`` → else the first
    surface marked ``focused`` → else the first surface. Raises LookupError when
    no terminal surface exists.
    """
    tabs = panes.get("tabs", [])
    active = panes.get("activeTab", 0)

    tab = next((t for t in tabs if t.get("index") == active and t.get("surfaces")), None)
    if tab is None:
        tab = next((t for t in tabs if t.get("surfaces")), None)
    if tab is None:
        raise LookupError("no tab with a live surface")

    fsid = tab.get("focusedSurfaceId")
    if fsid:
        return fsid

    surfaces = tab.get("surfaces", [])
    focused = next((s for s in surfaces if s.get("focused")), None)
    if focused:
        return focused["id"]
    if surfaces:
        return surfaces[0]["id"]
    raise LookupError("active tab has no surfaces")
```

- [ ] **Step 4: 跑测试确认通过**

Run: `/usr/bin/python3 -m pytest tests/macos_e2e/test_panes.py -v`
Expected: 4 passed

- [ ] **Step 5: Commit**

```bash
git add tests/macos_e2e/driver/panes.py tests/macos_e2e/test_panes.py
git commit -m "test(macos-e2e): pure panes JSON parser"
```

---

## Task 3: wait.py — 轮询等待(纯逻辑,TDD)

**Files:**
- Create: `tests/macos_e2e/driver/wait.py`
- Test: `tests/macos_e2e/test_wait.py`

- [ ] **Step 1: 写失败测试**

`tests/macos_e2e/test_wait.py`:

```python
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
```

- [ ] **Step 2: 跑测试确认失败**

Run: `/usr/bin/python3 -m pytest tests/macos_e2e/test_wait.py -v`
Expected: FAIL(import error)

- [ ] **Step 3: 实现**

`tests/macos_e2e/driver/wait.py`:

```python
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
```

- [ ] **Step 4: 跑测试确认通过**

Run: `/usr/bin/python3 -m pytest tests/macos_e2e/test_wait.py -v`
Expected: 3 passed

- [ ] **Step 5: Commit**

```bash
git add tests/macos_e2e/driver/wait.py tests/macos_e2e/test_wait.py
git commit -m "test(macos-e2e): pure polling wait helper"
```

---

## Task 4: keycodes.py — 键名→虚拟键码映射(纯逻辑,TDD)

**Files:**
- Create: `tests/macos_e2e/driver/keycodes.py`
- Test: `tests/macos_e2e/test_keycodes.py`

- [ ] **Step 1: 写失败测试**

`tests/macos_e2e/test_keycodes.py`:

```python
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
```

- [ ] **Step 2: 跑测试确认失败**

Run: `/usr/bin/python3 -m pytest tests/macos_e2e/test_keycodes.py -v`
Expected: FAIL(import error)

- [ ] **Step 3: 实现**

`tests/macos_e2e/driver/keycodes.py`:

```python
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
```

- [ ] **Step 4: 跑测试确认通过**

Run: `/usr/bin/python3 -m pytest tests/macos_e2e/test_keycodes.py -v`
Expected: 4 passed

- [ ] **Step 5: Commit**

```bash
git add tests/macos_e2e/driver/keycodes.py tests/macos_e2e/test_keycodes.py
git commit -m "test(macos-e2e): pure keyname-to-virtual-keycode table"
```

---

## Task 5: osascript.py — AppleScript 构造(纯)+ 运行器

**Files:**
- Create: `tests/macos_e2e/driver/osascript.py`
- Test: `tests/macos_e2e/test_osascript.py`

- [ ] **Step 1: 写失败测试(只测纯字符串构造)**

`tests/macos_e2e/test_osascript.py`:

```python
from tests.macos_e2e.driver.osascript import (
    activate_script, menu_click_script, menu_item_enabled_script,
    window_attr_script,
)


def test_activate_targets_pid():
    s = activate_script(4321)
    assert "unix id is 4321" in s
    assert "frontmost" in s


def test_menu_click_two_level_path():
    s = menu_click_script(4321, ["Edit", "Copy"])
    assert 'menu item "Copy"' in s
    assert 'menu "Edit"' in s
    assert 'menu bar item "Edit"' in s
    assert "unix id is 4321" in s


def test_menu_item_enabled_returns_boolean_expr():
    s = menu_item_enabled_script(7, ["Edit", "Copy"])
    assert "enabled of" in s
    assert 'menu item "Copy"' in s


def test_window_attr_script():
    s = window_attr_script(7, "size")
    assert "size of window 1" in s
    assert "unix id is 7" in s
```

- [ ] **Step 2: 跑测试确认失败**

Run: `/usr/bin/python3 -m pytest tests/macos_e2e/test_osascript.py -v`
Expected: FAIL(import error)

- [ ] **Step 3: 实现**

`tests/macos_e2e/driver/osascript.py`:

```python
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
```

- [ ] **Step 4: 跑测试确认通过**

Run: `/usr/bin/python3 -m pytest tests/macos_e2e/test_osascript.py -v`
Expected: 4 passed

- [ ] **Step 5: Commit**

```bash
git add tests/macos_e2e/driver/osascript.py tests/macos_e2e/test_osascript.py
git commit -m "test(macos-e2e): AppleScript builders + osascript runner"
```

---

## Task 6: ctl.py — wisptermctl 子进程封装

**Files:**
- Create: `tests/macos_e2e/driver/ctl.py`
- Test: `tests/macos_e2e/test_ctl.py`

集成代码(真实子进程由冒烟用例验证),但 `wait_for` 的轮询装配可单测(注入假 `get_text`)。

- [ ] **Step 1: 写失败测试(注入假 get_text 测 wait_for)**

`tests/macos_e2e/test_ctl.py`:

```python
import pytest
from tests.macos_e2e.driver.ctl import Ctl
from tests.macos_e2e.driver.wait import TimeoutError as WaitTimeout


class _FakeClock:
    def __init__(self):
        self.t = 0.0

    def monotonic(self):
        return self.t

    def sleep(self, s):
        self.t += s


def test_wait_for_matches_eventually(monkeypatch):
    c = Ctl(home="/tmp/x", binary="/bin/false")
    seq = iter(["", "loading", "ready: hello"])
    monkeypatch.setattr(c, "get_text", lambda pane, recent=None: next(seq))
    c.wait_for("pane1", "hello", timeout=10, interval=1, clock=_FakeClock())  # no raise


def test_wait_for_times_out(monkeypatch):
    c = Ctl(home="/tmp/x", binary="/bin/false")
    monkeypatch.setattr(c, "get_text", lambda pane, recent=None: "nope")
    with pytest.raises(WaitTimeout):
        c.wait_for("pane1", "hello", timeout=2, interval=1, clock=_FakeClock())
```

- [ ] **Step 2: 跑测试确认失败**

Run: `/usr/bin/python3 -m pytest tests/macos_e2e/test_ctl.py -v`
Expected: FAIL(import error)

- [ ] **Step 3: 实现**

`tests/macos_e2e/driver/ctl.py`:

```python
"""Wrapper around the `wisptermctl` CLI. Every call runs the binary with a fixed
HOME so it auto-discovers (and only ever talks to) the isolated test instance.
"""
import json
import os
import subprocess

from . import wait


class Ctl:
    def __init__(self, home: str, binary: str):
        self.home = home
        self.binary = binary

    def _run(self, args, timeout: float = 10.0) -> str:
        env = dict(os.environ)
        env["HOME"] = self.home
        proc = subprocess.run(
            [self.binary, *args],
            capture_output=True, text=True, env=env, timeout=timeout,
        )
        if proc.returncode != 0:
            raise RuntimeError(f"wisptermctl {args} failed: {proc.stderr.strip()}")
        return proc.stdout

    def panes(self) -> dict:
        return json.loads(self._run(["panes"]))

    def get_text(self, pane: str, recent=None) -> str:
        args = ["get-text", "-t", pane]
        if recent is not None:
            args += ["--recent", str(recent)]
        return self._run(args)

    def wait_for(self, pane: str, pattern: str, timeout: float = 5.0,
                 interval: float = 0.2, clock=wait._RealClock) -> None:
        wait.wait_until(
            lambda: wait.matches(self.get_text(pane), pattern),
            timeout=timeout, interval=interval, clock=clock,
        )
```

- [ ] **Step 4: 跑测试确认通过**

Run: `/usr/bin/python3 -m pytest tests/macos_e2e/test_ctl.py -v`
Expected: 2 passed

- [ ] **Step 5: Commit**

```bash
git add tests/macos_e2e/driver/ctl.py tests/macos_e2e/test_ctl.py
git commit -m "test(macos-e2e): wisptermctl subprocess wrapper"
```

---

## Task 7: quartz_input.py — CGEvent 键鼠合成

**Files:**
- Create: `tests/macos_e2e/driver/quartz_input.py`
- Test: `tests/macos_e2e/test_quartz_input.py`

集成代码(实际事件投递由冒烟用例验证);`mods_to_flags` 是可单测的纯映射(在 macOS 上 import Quartz 成功即可跑)。

- [ ] **Step 1: 写失败测试(只测 mods_to_flags)**

`tests/macos_e2e/test_quartz_input.py`:

```python
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
```

- [ ] **Step 2: 跑测试确认失败**

Run: `/usr/bin/python3 -m pytest tests/macos_e2e/test_quartz_input.py -v`
Expected: FAIL(import error on quartz_input)

- [ ] **Step 3: 实现**

`tests/macos_e2e/driver/quartz_input.py`:

```python
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
```

- [ ] **Step 4: 跑测试确认通过**

Run: `/usr/bin/python3 -m pytest tests/macos_e2e/test_quartz_input.py -v`
Expected: 1 passed

- [ ] **Step 5: Commit**

```bash
git add tests/macos_e2e/driver/quartz_input.py tests/macos_e2e/test_quartz_input.py
git commit -m "test(macos-e2e): CGEvent keyboard/mouse synthesis"
```

---

## Task 8: base.py — Driver 抽象接口 + ItemState

**Files:**
- Create: `tests/macos_e2e/driver/base.py`
- Test: `tests/macos_e2e/test_base.py`

- [ ] **Step 1: 写失败测试**

`tests/macos_e2e/test_base.py`:

```python
from tests.macos_e2e.driver.base import ItemState, Driver


def test_item_state_fields():
    s = ItemState(enabled=True, checked=None)
    assert s.enabled is True
    assert s.checked is None


def test_driver_is_protocol_with_expected_methods():
    for name in ["launch", "quit", "focus", "primary_pane", "key", "text",
                 "click", "menu_click", "menu_item_state", "window_attr",
                 "get_text", "wait_for"]:
        assert hasattr(Driver, name)
```

- [ ] **Step 2: 跑测试确认失败**

Run: `/usr/bin/python3 -m pytest tests/macos_e2e/test_base.py -v`
Expected: FAIL(import error)

- [ ] **Step 3: 实现**

`tests/macos_e2e/driver/base.py`:

```python
"""Platform-agnostic driver contract. Test cases depend only on this. The
terminal-text layer (get_text/wait_for/primary_pane) is reused verbatim by a
future Windows backend; only the input + menu/window methods are reimplemented.
"""
from dataclasses import dataclass
from typing import Optional, Protocol, runtime_checkable


@dataclass
class ItemState:
    enabled: bool
    checked: Optional[bool] = None


@runtime_checkable
class Driver(Protocol):
    def launch(self, *, cols: int = 80, rows: int = 24) -> None: ...
    def quit(self) -> None: ...
    def focus(self) -> None: ...
    def primary_pane(self) -> str: ...
    # real input
    def key(self, key: str, *mods: str) -> None: ...
    def text(self, s: str) -> None: ...
    def click(self, x: int, y: int, *, count: int = 1) -> None: ...
    # menu / window
    def menu_click(self, *path: str) -> None: ...
    def menu_item_state(self, *path: str) -> ItemState: ...
    def window_attr(self, name: str) -> str: ...
    # terminal text (cross-platform)
    def get_text(self, pane: str, recent: Optional[int] = None) -> str: ...
    def wait_for(self, pane: str, pattern: str, timeout: float = 5.0) -> None: ...
```

- [ ] **Step 4: 跑测试确认通过**

Run: `/usr/bin/python3 -m pytest tests/macos_e2e/test_base.py -v`
Expected: 2 passed

- [ ] **Step 5: Commit**

```bash
git add tests/macos_e2e/driver/base.py tests/macos_e2e/test_base.py
git commit -m "test(macos-e2e): Driver protocol + ItemState"
```

---

## Task 9: macos.py — MacDriver(组装 + app 生命周期)

**Files:**
- Create: `tests/macos_e2e/driver/macos.py`

集成代码,无独立单测;由 Task 11 的冒烟用例验证。

- [ ] **Step 1: 实现 MacDriver**

`tests/macos_e2e/driver/macos.py`:

```python
"""macOS backend: composes Quartz input + osascript (menu/AX) + wisptermctl
(text), and owns the isolated WispTerm.app instance lifecycle.
"""
import os
import signal
import subprocess
import tempfile
import time

from . import keycodes, osascript, quartz_input, wait
from .base import ItemState
from .ctl import Ctl
from .panes import primary_pane_id

_CONFIG = (
    "agent-control-enabled = true\n"
    "auto-update-check = false\n"
    "font-size = 14\n"
)


class MacDriver:
    def __init__(self, app_bundle: str, ctl_binary: str):
        # app_bundle: .../zig-out/bin/WispTerm.app ; ctl_binary: .../zig-out/bin/wisptermctl
        self.exe = os.path.join(app_bundle, "Contents", "MacOS", "WispTerm")
        self.ctl_binary = ctl_binary
        self.home = tempfile.mkdtemp(prefix="wispterm-e2e-")
        self.proc = None
        self.ctl = Ctl(home=self.home, binary=self.ctl_binary)

    # ---- lifecycle ----
    def _config_dir(self) -> str:
        return os.path.join(self.home, "Library", "Application Support", "wispterm")

    def launch(self, *, cols: int = 80, rows: int = 24) -> None:
        cfg_dir = self._config_dir()
        os.makedirs(cfg_dir, exist_ok=True)
        with open(os.path.join(cfg_dir, "config"), "w") as f:
            f.write(_CONFIG)

        env = dict(os.environ)
        env["HOME"] = self.home
        self.proc = subprocess.Popen([self.exe], env=env)

        # wait for the control server to publish its discovery file, then for a
        # live terminal surface to exist.
        disc = os.path.join(cfg_dir, "agent-control.json")
        wait.wait_until(lambda: os.path.exists(disc), timeout=15, interval=0.2)
        wait.wait_until(self._has_terminal_surface, timeout=15, interval=0.2)
        self.focus()

    def _has_terminal_surface(self) -> bool:
        try:
            primary_pane_id(self.ctl.panes())
            return True
        except Exception:
            return False

    def quit(self) -> None:
        if self.proc and self.proc.poll() is None:
            self.proc.send_signal(signal.SIGTERM)
            try:
                self.proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.proc.kill()
        import shutil
        shutil.rmtree(self.home, ignore_errors=True)

    def focus(self) -> None:
        osascript.run(osascript.activate_script(self.proc.pid))
        time.sleep(0.3)  # let activation settle before posting events

    # ---- discovery ----
    def primary_pane(self) -> str:
        return primary_pane_id(self.ctl.panes())

    # ---- real input ----
    def key(self, key_name: str, *mods: str) -> None:
        for m in mods:
            if m not in keycodes.MODIFIERS:
                raise ValueError(f"unknown modifier: {m}")
        quartz_input.key(keycodes.keycode(key_name), quartz_input.mods_to_flags(list(mods)))

    def text(self, s: str) -> None:
        for ch in s:
            if ch in ("\n", "\r"):
                self.key("return")
            else:
                quartz_input.type_char(ch)

    def click(self, x: int, y: int, *, count: int = 1) -> None:
        quartz_input.click(x, y, count=count)

    # ---- menu / window ----
    def menu_click(self, *path: str) -> None:
        osascript.run(osascript.menu_click_script(self.proc.pid, list(path)))

    def menu_item_state(self, *path: str) -> ItemState:
        out = osascript.run(osascript.menu_item_enabled_script(self.proc.pid, list(path)))
        return ItemState(enabled=(out.strip().lower() == "true"))

    def window_attr(self, name: str) -> str:
        return osascript.run(osascript.window_attr_script(self.proc.pid, name))

    # ---- terminal text ----
    def get_text(self, pane: str, recent=None) -> str:
        return self.ctl.get_text(pane, recent)

    def wait_for(self, pane: str, pattern: str, timeout: float = 5.0) -> None:
        self.ctl.wait_for(pane, pattern, timeout=timeout)

    def read_clipboard(self) -> str:
        return osascript.run(osascript.clipboard_script())
```

- [ ] **Step 2: 语法/导入自检**

Run: `/usr/bin/python3 -c "import tests.macos_e2e.driver.macos"`
Expected: 退出 0(在 macOS 上 import Quartz 成功;无运行时副作用)

- [ ] **Step 3: Commit**

```bash
git add tests/macos_e2e/driver/macos.py
git commit -m "test(macos-e2e): MacDriver composing input + osascript + ctl"
```

---

## Task 10: conftest.py — app fixture + 预检

**Files:**
- Modify: `tests/macos_e2e/conftest.py`

- [ ] **Step 1: 追加 fixture 与预检**

在 `tests/macos_e2e/conftest.py` 末尾追加:

```python
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
```

- [ ] **Step 2: 验证非 e2e 单测仍全绿、e2e 在缺产物时被 skip(不报错)**

Run: `/usr/bin/python3 -m pytest tests/macos_e2e -v`
Expected: 纯单测(panes/wait/keycodes/osascript/ctl/base/quartz)全 passed;若此刻还没建 e2e 用例则无 e2e 项。无 ERROR。

- [ ] **Step 3: Commit**

```bash
git add tests/macos_e2e/conftest.py
git commit -m "test(macos-e2e): session app fixture with permission/artifact prechecks"
```

---

## Task 11: 三个冒烟用例(集成验证)

**Files:**
- Create: `tests/macos_e2e/test_smoke.py`
- Create: `tests/macos_e2e/test_keybinds.py`
- Create: `tests/macos_e2e/test_menu.py`

- [ ] **Step 1: echo 往返**

`tests/macos_e2e/test_smoke.py`:

```python
import pytest


@pytest.mark.e2e
def test_echo_roundtrip(app, pane):
    app.text("echo hello-e2e\n")          # real keyboard events through full input path
    app.wait_for(pane, "hello-e2e", timeout=8)   # assert via control channel
```

- [ ] **Step 2: Cmd+C 复制绑定**

`tests/macos_e2e/test_keybinds.py`:

```python
import time
import pytest


@pytest.mark.e2e
def test_cmd_c_copies_selection(app, pane):
    marker = "copy-me-e2e"
    app.text(marker)
    app.wait_for(pane, marker, timeout=8)
    app.key("a", "cmd")                   # Select All
    time.sleep(0.2)
    app.key("c", "cmd")                   # Copy
    time.sleep(0.2)
    assert marker in app.read_clipboard()
```

- [ ] **Step 3: Edit > Copy 菜单启用状态**

`tests/macos_e2e/test_menu.py`:

```python
import time
import pytest
from tests.macos_e2e.conftest import macos_only


@pytest.mark.e2e
@macos_only
def test_edit_copy_enabled_tracks_selection(app, pane):
    # With no selection, Edit > Copy is disabled.
    assert app.menu_item_state("Edit", "Copy").enabled is False
    # After typing + Select All, it becomes enabled.
    app.text("xyz")
    app.wait_for(pane, "xyz", timeout=8)
    app.key("a", "cmd")
    time.sleep(0.3)
    assert app.menu_item_state("Edit", "Copy").enabled is True
```

- [ ] **Step 4: 真机运行全部 e2e(需已授辅助功能权限)**

Run: `make test-macos-e2e`
Expected: 构建出 `.app` + `wisptermctl`,启动隔离实例,3 个 e2e 用例 + 全部单测 passed。若菜单项名(Edit/Copy)与实际不符,据 `osascript` 报错调整 `test_menu.py` 路径;若未授权则相关用例 skip 并提示授权。

> 注:Step 4 是真实 GUI 集成验证,可能因菜单标题、激活时序等需要微调。逐项核对 osascript 报错与 `app.get_text(pane)` dump。

- [ ] **Step 5: Commit**

```bash
git add tests/macos_e2e/test_smoke.py tests/macos_e2e/test_keybinds.py tests/macos_e2e/test_menu.py
git commit -m "test(macos-e2e): echo / Cmd+C / Edit-Copy smoke tests"
```

---

## Task 12: README + 收尾

**Files:**
- Create: `tests/macos_e2e/README.md`

- [ ] **Step 1: 写 README**

`tests/macos_e2e/README.md`:

````markdown
# macOS UI E2E 测试

本地运行的端到端 GUI 测试:启动隔离的真实 `WispTerm.app`,用真实 OS 输入驱动,
断言终端正文与窗口/菜单状态。

## 运行

```bash
make test-macos-e2e
```

会先按本机架构构建 `macos-app` + `wisptermctl`,确保 `pytest` 在位(缺则
`pip install --user pytest`),再用 `/usr/bin/python3 -m pytest tests/macos_e2e`。

## 前置条件

- macOS + Xcode 或 Command Line Tools(提供 `/usr/bin/python3`)。
- **PyObjC**(非系统自带,需一次 pip):
  `/usr/bin/python3 -m pip install --user pyobjc-framework-Quartz pyobjc-framework-Cocoa`。
  未安装时 e2e 用例自动 skip 并给出该命令。
- **pytest**:`make` 入口会在缺失时自动 `pip install --user pytest`。
- 运行 pytest 的终端需在 **系统设置 → 隐私与安全性 → 辅助功能** 中授权
  (CGEvent 注入 + System Events 控制);未授权时 e2e 用例自动 skip 并提示。
- 解释器固定用 `/usr/bin/python3`(其 user-site 挂着 PyObjC);其他 python 可能没有 PyObjC。

## 隔离

每次 session 用临时 `HOME`,在其中写 `config`(开启 `agent-control-enabled`、
关闭 `auto-update-check`)。所有 `wisptermctl` 调用带同一 `HOME`,只连测试实例,
**不影响你正在用的开发实例**。

## 结构

- `driver/base.py` — 跨平台抽象接口(用例只依赖它)
- `driver/macos.py` — MacDriver:CGEvent(键鼠)+ osascript(菜单/AX)+ wisptermctl(正文)
- 纯逻辑模块(`panes`/`keycodes`/`wait`/`osascript` 构造)有单元测试,无需 GUI
- `test_smoke.py` / `test_keybinds.py` / `test_menu.py` — 标 `@pytest.mark.e2e`

## 扩展 / Windows

新增后端 `driver/windows.py`(`SendInput` via ctypes + UI Automation),
正文层(`get_text`/`wait_for`/`primary_pane`)直接复用;`conftest` 按平台选后端。
````

- [ ] **Step 2: Commit**

```bash
git add tests/macos_e2e/README.md
git commit -m "docs(macos-e2e): harness README"
```

---

## 自检结果(spec 覆盖核对)

- **真实输入路径**(spec §2)→ Task 7(quartz)+ Task 9(MacDriver.key/text)+ Task 11(echo/Cmd+C)。✅
- **终端正文输出**(spec §2)→ Task 6(ctl)+ Task 2(panes)+ Task 11(wait_for 断言)。✅
- **窗口/菜单状态**(spec §2)→ Task 5(osascript)+ Task 9(menu_item_state/window_attr)+ Task 11(test_menu)。✅
- **实例隔离 = HOME 覆盖 + 开 agent-control**(spec §3,§7)→ Task 9(launch 写 config + Popen env)+ Task 10(fixture)。✅
- **抽象接口/后端分离**(spec §6)→ Task 8(base)+ Task 9(macos);用例仅依赖 base/conftest。✅
- **入口独立于 zig build test**(spec §10)→ Task 1(Makefile target)。✅
- **依赖现实**(spec §2 修正)→ 固定 `/usr/bin/python3` + user-site PyObjC(已有)+ osascript;pytest 由 Makefile 引导安装;conftest 对 PyObjC 缺失给安装指引。✅
- **不做截图 diff**(spec §2 非目标)→ 计划无任何截图/图像对比。✅
- **fixture 粒度 = session 共享 + 每 test 新 pane**(spec §12)→ Task 10(session `app` + 函数级 `pane`)。✅
- **首版 3 用例**(spec §12)→ Task 11。✅

类型一致性核对:`Ctl`/`MacDriver`/`ItemState`/`primary_pane_id`/`wait_until`/`keycode`/`mods_to_flags` 在定义任务与使用任务中签名一致。✅
