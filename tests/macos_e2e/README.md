# macOS UI E2E 测试

本地运行的端到端 GUI 测试:启动隔离的真实 `WispTerm.app`,断言终端正文(经控制通道)
与窗口/菜单状态(经 Accessibility)。

## 运行

```bash
make test-macos-e2e
```

会先按本机架构构建 `macos-app` + `wisptermctl`,确保 `pytest` 在位(缺则
`pip install --user pytest`),再用 `/usr/bin/python3 -m pytest tests/macos_e2e`。

只跑无需 GUI 的纯逻辑单测:

```bash
/usr/bin/python3 -m pytest tests/macos_e2e -m "not e2e"
```

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
- `driver/macos.py` — MacDriver:`open` 隔离启动 + CGEvent(键鼠,真实路径)+ osascript(菜单/AX)
  + wisptermctl(`send_text`/`get_text`,控制通道)
- 纯逻辑模块(`panes`/`keycodes`/`wait`/`osascript` 构造/`ctl` 装配)有单元测试,无需 GUI
- `test_smoke.py` — 控制通道 echo 往返(启动 + 配置 + 控制服务 + shell + get-text)
- `test_menu.py` — `Edit ▸ Copy` 菜单状态读取(osascript→AX,真实)
- `test_keybinds.py` — 真实 Cmd+C 复制,**当前 `skip`**(见下方已知限制)

## 已知限制(见 issue #279)

合成的输入**动作**(键盘、菜单点击)在"程序化启动"的测试实例里**不被处理**:事件能
到达 `-keyDown:`、`interpretKeyEvents:`→`insertText:` 也能触发,但字符/动作始终到不了
PTY;`File ▸ New Tab` 菜单点击也不改变标签数。仅**读取**(AX 菜单/窗口状态、`get-text`、
`panes`)和**控制通道写入**(`send-text`)可用。已排除环境因素:同样的 CGEvent 在本机能
正常打字进 TextEdit,`AXIsProcessTrusted()` 为真,Secure Input 关闭,实例为真实前台、窗口
为 key。疑似与"隔离实例启动即开 2 个 tab、`activeTab` 上报为 0"同源。

因此本期 harness 用**控制通道**做文本输入、用 **AX** 读菜单/窗口状态;真实键盘/菜单动作
路径待 [#279](https://github.com/xuzhougeng/wispterm/issues/279) 修复后,用 `driver/macos.py`
里保留的 `text()`/`key()`/`menu_click()`(CGEvent/osascript)直接接通,并取消
`test_keybinds.py` 的 skip。

## 扩展 / Windows

新增后端 `driver/windows.py`(`SendInput` via ctypes + UI Automation),
正文层(`get_text`/`wait_for`/`primary_pane`)直接复用;`conftest` 按平台选后端。
