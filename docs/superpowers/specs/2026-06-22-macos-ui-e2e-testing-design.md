# macOS UI 端到端(E2E)测试 harness — 设计文档

- 日期:2026-06-22
- 状态:已通过设计评审,待写 spec 评审 → 实施计划
- 范围:为 phantty(WispTerm)新增一套**本地运行**的 macOS GUI 自动化测试 harness;结构上为后续 Windows 复用预留接缝。

## 1. 背景与问题

当前项目已有的"UI 测试"是**进程内 Zig 冒烟测试**(`test-macos-ui` / `test-macos-window` / `test-macos-menu` / `test-macos-font` / `test-macos-services`),它们链接 AppKit/CoreText 并运行模块内的 `test{}` 块。例如 `src/test_macos_ui.zig` 实际只 `@import("input.zig")` 与 `renderer/overlays.zig`。

这类测试**不会启动真正的 `.app`,也不模拟真实 OS 级输入**,因此覆盖不到"用户敲键 → 桥接 → Surface → 渲染"这条完整链路。近期反复出问题的 bug 恰好都在这条链路上:Cmd+C 复制绑定、NSMenu 快捷键、粘贴图片、overlay 方向键"不跟手"、双击标题栏最大化、退出响铃等。缺一套能驱动真实运行实例的端到端 UI 测试。

项目已具备两块可复用基础:

- **控制通道** `wisptermctl` + `src/ctl/`:命令 `panes` / `get-text -t <id> [--recent N]` / `send-text -t <id> <data>` / `wait-for -t <id> <pattern> [--timeout N]`。
  - 走 **TCP loopback**(`127.0.0.1:port`,`src/ctl/server.zig:33`),非 Unix socket;`setReadTimeout` 已含 Windows 分支。
  - 实例发现靠 config 目录下的 `agent-control.json`(端口+token,`src/ctl/discovery.zig`)。
  - `wisptermctl` 在 build.zig 中标注 "on every desktop target",**Windows 上也能编出来**。
- **CGEvent 先例**:已验证用 `/usr/bin/python3` + Quartz 合成键鼠事件(含屏幕坐标 ×1.319 缩放校正)。

## 2. 目标与非目标

### 目标
- 启动**真实运行的 `WispTerm.app` 测试实例**,用**真实 OS 输入**驱动它,并对结果做断言。
- 覆盖三层行为:
  1. **真实输入路径**(键盘/快捷键/菜单/焦点/点击)
  2. **终端正文输出**(命令执行后面板内的文本)
  3. **窗口/菜单状态**(标题栏、菜单项 enabled/checked、窗口尺寸等)
- 输入/AX 用 **macOS 系统能力**(CGEvent、AppleScript),正文用项目自带 `wisptermctl`。
- 架构上将**抽象接口 / 平台后端**分离,为 Windows 复用预留接缝。

> **依赖现实(修正早期"零安装"说法)**:`/usr/bin/python3`(Xcode/CLT,3.9)**不自带 PyObjC**——本机的 `Quartz`/`ApplicationServices` 是 `pip install --user` 装的(位于 `~/Library/Python/3.9/.../site-packages`)。`pytest` 也未预装。因此真实依赖 = **PyObjC 框架(本机已有)+ pytest(需一次 `pip install --user pytest`)**。harness 在缺失时给出清晰的安装指引而非静默失败。

### 非目标
- **不做视觉渲染截图 diff**(基准维护成本高,本期明确排除)。
- **不接 CI 门禁**(本期定位为本地开发验证;CI 化为后续话题)。
- **不实现 Windows 后端**(仅预留接缝,不在本期落地)。
- 不修改控制通道协议(直接复用现有 `wisptermctl` 命令面)。

## 3. 关键决策

- **编排方案 = Python harness(pytest)**。理由:真测试框架(fixture 管生命周期、清晰断言、重试/等待 helper);键鼠与断言同一语言。运行解释器固定用 `/usr/bin/python3`(它的 user-site 同时挂着 PyObjC 与 pytest);`make` 入口在 pytest 缺失时自动 `pip install --user pytest`。
- **三层底层原语**:
  - 真实输入(键鼠)→ CGEvent(Quartz)
  - 菜单动作 + 窗口/菜单状态读取 → AppleScript System Events / AX(`osascript`)
  - 终端正文断言 → `wisptermctl get-text` / `wait-for`
- **正文断言层天然跨平台**:`wisptermctl` 走 TCP + JSON 发现,Windows 后端可一行不改地复用。
- **实例隔离 = 覆盖 `HOME`**(macOS config 目录为 `$HOME/Library/Application Support/wispterm`,`app_dir_name = "wispterm"`,`dirs.zig:4,42-46`,**不读 `XDG_CONFIG_HOME`**)。Windows 以后覆盖 `APPDATA`。
- **fixture 粒度 = session 级共享一个实例 + 每个 test 开新 tab/pane 做隔离**(快;用例间通过独立 pane 避免污染)。
- **首版用例 = 3 个冒烟用例**(echo 往返 / Cmd+C 复制 / 菜单 enabled),先验证 harness 跑通,再逐步扩充回归集。

## 4. 架构总览

```
pytest 用例 (仅依赖抽象 base 接口)
        │
   conftest fixture  ──launch──►  WispTerm.app 测试实例 (HOME=临时目录,隔离)
        │                              │  写 agent-control.json (port+token)
        ▼                              ▼
   MacDriver(base)               控制服务 (TCP 127.0.0.1:port)
   ├─ 真实输入  → CGEvent (/usr/bin/python3 + Quartz) ──► 运行中的窗口
   ├─ 菜单/窗口 → osascript System Events / AX        ──► 进程 chrome
   └─ 正文断言  → wisptermctl get-text/wait-for (同一 HOME) ◄── 控制服务
```

控制进程(运行 pytest 的终端)需要**辅助功能(Accessibility)权限**;因不截图,**不需要屏幕录制权限**。

## 5. 目录结构

```
tests/macos_e2e/
  conftest.py            # app 生命周期 fixture + 按平台选后端 + 权限预检
  driver/
    base.py              # 抽象接口(用例只依赖它)
    macos.py             # MacDriver:CGEvent + osascript + wisptermctl
    # windows.py         # 以后:WinDriver:SendInput(ctypes) + UIA;正文层复用
  _quartz_input.py       # CGEvent 键鼠合成(沉淀自既有 python Quartz 脚本)
  test_smoke.py          # 启动→敲命令→看输出→退出
  test_keybinds.py       # Cmd+C / 菜单快捷键 等"真实输入"回归
  test_menu.py           # 标题栏 / 菜单项 enabled/checked(@macos_only)
```

## 6. Driver 抽象接口(用例契约,跨平台稳定)

```python
class Driver(Protocol):
    def launch(self, *, cols=80, rows=24) -> None: ...
    def quit(self) -> None: ...
    def focus(self) -> None: ...                       # 窗口提到前台 + 抢焦点
    def primary_pane(self) -> str: ...                 # wisptermctl panes → surface id
    # 真实输入(平台后端各自实现)
    def key(self, key: str, *mods: str) -> None: ...   # "c","return","f2"; mods: cmd/ctrl/shift/alt
    def text(self, s: str) -> None: ...                # 逐字符真实键入
    def click(self, x: int, y: int, *, count=1) -> None: ...
    # 菜单/窗口(平台后端各自实现)
    def menu_click(self, *path: str) -> None: ...      # ("Edit","Copy")
    def menu_item_state(self, *path: str) -> ItemState: ...  # enabled / checked
    def window_attr(self, name: str): ...              # size / position / title …
    # 正文断言(跨平台,Windows 直接复用)
    def get_text(self, pane: str, recent: int | None = None) -> str: ...
    def wait_for(self, pane: str, pattern: str, timeout=5.0) -> None: ...
```

**复用边界**:`launch/quit/primary_pane/get_text/wait_for` 落到进程管理 + `wisptermctl`,跨平台几乎照搬;仅 `key/text/click/menu_*/window_attr` 需平台后端各自实现。

## 7. 实例隔离与生命周期(关键正确性)

fixture(session 级)执行:

1. `zig build macos-app` 构建 `.app`;在 zig 安装目录定位 bundle `WispTerm.app`,可执行文件 `WispTerm.app/Contents/MacOS/WispTerm`(`build.zig:148,161`)。
2. 建临时 `HOME=/tmp/wispterm-e2e-XXXX`,写入最小 config(固定字号/主题、禁用更新检查),保证渲染与行为确定性。
3. **直接执行 bundle 内可执行文件**(而非 `open -a`):可传 `HOME` 环境变量、拿到 PID、避免复用开发者正在运行的实例。
4. 轮询 `$HOME/Library/Application Support/wispterm/agent-control.json` 出现 → 判定实例就绪。
5. 所有 `wisptermctl` 调用都带同一 `HOME` env → 必然连到测试实例,**不触碰开发者实例**。
6. teardown:优雅退出(`wisptermctl` 退出指令或信号)→ 等 PID 消失 → 删除临时 HOME。

每个 test 通过新 tab/pane 隔离;`primary_pane()` 用 `wisptermctl panes` 解析当前目标 surface id。

## 8. 真实输入实现要点(MacDriver)

- **键鼠走 CGEvent**(`/usr/bin/python3` + Quartz):`CGEventCreateKeyboardEvent` 发 keycode + 修饰键,`CGEventPost` 注入系统事件流 → 落到前台焦点窗口;鼠标坐标沿用 **×1.319** 缩放校正。
- **每次输入前先 `focus()`**:CGEvent 投递给前台焦点窗口,fixture 必须先 activate 测试实例,否则事件发错对象。
- **菜单动作走 osascript**:`tell process "WispTerm" to click menu item "Copy" of menu "Edit"`,比合成菜单导航稳。
- **窗口/菜单状态读取走 AX**:`osascript` 读 `enabled` / `value`(勾选)/ `size of window 1`。AX 能读窗口 chrome;**仅终端正文 AX 读不到**(Metal 单 drawable 渲染),所以正文才走控制通道。
- **剪贴板断言**:通过 `osascript`(NSPasteboard / `the clipboard`)读取,用于 Cmd+C 类用例。

## 9. 首版示例用例

```python
def test_echo_roundtrip(app):                  # app = launched MacDriver fixture
    pane = app.primary_pane()
    app.focus()
    app.text("echo hello-e2e\n")               # 真实键盘事件,走完整输入路径
    app.wait_for(pane, "hello-e2e", timeout=5) # 控制通道断言正文

def test_cmd_c_copy_binding(app):              # 回归 Cmd+C 复制绑定一类 bug
    pane = app.primary_pane()
    app.focus()
    app.text("copy-me")
    app.key("a", "cmd"); app.key("c", "cmd")   # 全选 + Cmd+C 真实快捷键
    assert "copy-me" in read_clipboard()       # NSPasteboard via osascript

@macos_only
def test_edit_menu_copy_enabled_on_selection(app):
    assert app.menu_item_state("Edit", "Copy").enabled is False  # 无选区时禁用
    app.text("xyz"); app.key("a", "cmd")
    assert app.menu_item_state("Edit", "Copy").enabled is True
```

## 10. 入口、抖动控制、风险

- **入口**:`make test-macos-e2e`(内部 `python3 -m pytest tests/macos_e2e`)。**不**并入默认 `zig build test`——E2E 需要真实 GUI 会话 + 辅助功能权限,不应卡常规构建。
- **抖动控制**:断言一律走 `wait_for`(轮询 + 超时),不用固定 sleep;`focus()` 后留小停顿等 activation;失败时 dump `get-text` 全文 + 窗口 AX 树,便于排查。
- **已知风险**:
  1. 辅助功能权限缺失 → fixture 预检并给清晰报错(指明在"系统设置 → 隐私与安全性 → 辅助功能"授权运行 pytest 的终端)。
  2. 直接 exec GUI bundle 的 activation policy 偶发不抢焦点 → 用 osascript `activate` 兜底。
  3. 双实例并存 → 靠 `HOME` 隔离 + teardown 清理。

## 11. Windows 未来接缝(本期不实现)

- 新增 `driver/windows.py`:`key/text/click` 用 stdlib `ctypes` 调 `SendInput`(免装);`menu_* / window_attr` 用 UI Automation(需 `comtypes` / `pywinauto`)。
- **正文层(`get_text/wait_for/primary_pane/launch/quit`)一行不改**,复用 `wisptermctl`。
- `conftest` 按 `sys.platform` 选后端;菜单/标题栏专属用例用 `@macos_only` 跳过(两平台菜单模型不同)。
- 安装面对比:macOS 需 PyObjC + pytest(均 pip);Windows 还需安装 Python 本体 + UIA 包(`comtypes`/`pywinauto`),`SendInput` 用 stdlib `ctypes` 免装。

## 12. 已确认的决策点(评审中可改)

- fixture 粒度:**session 级共享实例 + 每 test 新 pane 隔离**。
- 首版用例集:**3 个冒烟用例**(echo 往返 / Cmd+C 复制 / 菜单 enabled)。

## 13. 验收标准

- `make test-macos-e2e` 在本地 macOS(已授予辅助功能权限)上启动隔离实例并 3 个用例全绿。
- 运行**不影响**开发者正在使用的 WispTerm 实例(HOME 隔离验证)。
- driver 抽象接口与 MacDriver 实现分离,`base.py` 不含任何 macOS 专有调用。
- 入口独立于 `zig build test`,不拖慢常规构建。
