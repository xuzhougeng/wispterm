# macOS UI 开发经验总结

本文档记录把 WispTerm 从"只有外壳"的 macOS 端口推到"功能与 Windows 对齐"过程中踩到的坑。
对应的代码改动见 [PR #73](https://github.com/xuzhougeng/wispterm/pull/73)（Complete macOS UI: NSMenu + Metal overlay rendering + zsh default）。

适用对象：未来想把 WispTerm 移植到新平台、或在现有 Metal/AppKit 代码上做改动的人。

---

## 表象 vs. 根因

最初的症状是 macOS 端的 WispTerm 启动后只看到终端字符 `sh-3.2$`，但
**所有 overlay（命令面板、侧边栏、SSH 表单、设置页）都不可见**。NSMenu 回调能触发、
state 切换正确，但屏幕上看不到任何 panel/边框/高亮。

如果只看症状，很自然会怀疑：
- "Metal pipeline 还没接好" — 实际 MSL shader、Pipeline、Buffer、Texture 早已就绪
- "需要新写一套 solid-color quad batch" — 实际 ui_pipeline 已经是 cross-backend 的，
  Metal 的 Pipeline.drawArrays 也真的把命令编进了 MTLRenderCommandEncoder
- "需要做 ring buffer / triple-buffering" — 实际只需要一处 buffer-allocation 修复

**真正的两个 bug 都只有几行代码**，但它们各自打断了 OpenGL→Metal 的等价契约，
诊断花了不少时间。下文按"发现顺序"展开。

---

## Bug #1：Metal stub 没委托给 ui_pipeline

### 现象
- `ui_pipeline.fillQuad/fillQuadAlpha` 在 OpenGL 上正常画方块
- 同一份 `ui_pipeline.zig` 在 Metal 上不画方块
- `gpu/metal/Pipeline.drawArrays` 添加 fprintf 后**能**看到 draw 调用进入 Metal encoder
- 但屏幕没有任何 fillQuad 结果

### 根因
对比 `gpu/opengl/gl_init.zig` 和 `gpu/metal/gl_init.zig`：

```zig
// opengl/gl_init.zig
pub fn setProjection(width: f32, height: f32) void {
    ui_pipeline.setProjection(width, height);  // 把矩阵写入 text pipeline 的 uniform
}

// metal/gl_init.zig  (原版 stub)
pub fn setProjection(width: f32, height: f32) void {
    render_state.setViewport(0, 0, @intFromFloat(width), @intFromFloat(height));
    // ← 漏了 ui_pipeline.setProjection！
}
```

`ui_pipeline.setProjection` 是唯一往 text pipeline 写正交投影矩阵的入口。Metal 后端
没调用它 → text pipeline 的 `uniforms.projection` 永远是 `calloc` 出来的**零矩阵** →
每个顶点 `(x, y, 0, 1) × 零矩阵 = (0, 0, 0, 0)` → 全部塌缩到 clip space 原点 →
看起来"完全没渲染"。

终端字符之所以能显示，是因为它走的是 `cell_pipeline`，那条路径有自己的 projection
uniform 注入（不经过 ui_pipeline.setProjection），所以幸免于难。

### 教训
- **OpenGL↔Metal 的等价契约要在两个文件级别都对齐**。"stub 仅占位"的注释非常危险，
  因为它绕过了类型检查 —— stub 完全合法编译，但语义上偷偷少做了一件事。
- 加 comptime 守卫，比如要求两个 `gl_init.zig` 暴露完全相同的 public 函数体（不只是签名），
  会让这类断点在编译期就暴露。
- 调试时**对比 OpenGL 等价路径**比单独 trace Metal 路径更快定位。

### 工程化修复
不能简单地在 `metal/gl_init.zig` 顶部加 `@import("../../ui_pipeline.zig")`，
因为 `test-metal` 的 module root 是 `gpu/metal/`，Zig 0.15 拒绝 import 走出 root：

```
error: import of file outside module path
const ui_pipeline = @import("../../ui_pipeline.zig");
```

解法：**函数指针 hooks**。`metal/gl_init.zig` 声明 `BackendHooks`，
`ui_pipeline.init()` 在 app 启动时调 `setBackendHooks` 注册。
hooks nil 时 helper 静默 no-op（满足 test-metal 没有 ui_pipeline 的场景），
hooks 非 nil 时正常委托。

```zig
// gpu/metal/gl_init.zig
pub const BackendHooks = struct {
    fillQuad: *const fn (f32, f32, f32, f32, [3]f32) void,
    fillQuadAlpha: *const fn (f32, f32, f32, f32, [3]f32, f32) void,
    setProjection: *const fn (f32, f32) void,
};
threadlocal var g_hooks: ?BackendHooks = null;

pub fn setBackendHooks(hooks: BackendHooks) void { g_hooks = hooks; }
pub fn setProjection(width: f32, height: f32) void {
    render_state.setViewport(0, 0, @intFromFloat(width), @intFromFloat(height));
    if (g_hooks) |h| h.setProjection(width, height);
}

// renderer/ui_pipeline.zig
fn registerMetalBackendHooks() void {
    if (!@hasDecl(AppWindow.gpu.gl_init, "setBackendHooks")) return;
    AppWindow.gpu.gl_init.setBackendHooks(.{ /* ... */ });
}
```

`@hasDecl` 让同一段代码在 OpenGL backend（没有 BackendHooks 这个符号）下编译成 no-op。

---

## Bug #2：Metal MTLBuffer 共享 storage 在 deferred commit 下被覆盖

### 现象（在 Bug #1 修好之后才暴露出来）
- 文字渲染正常
- 但所有 `ui_pipeline.fillQuad` 调用画出来的 quad 只剩**最后一个**

### 根因：Metal 异步执行 vs. OpenGL 同步

OpenGL 的 `glBufferSubData` 即便不 fence，驱动也会在 next draw 之前把新数据落地，
所以 "upload+draw, upload+draw, upload+draw" 工作正常。

Metal 不一样：

```objc
[encoder setVertexBuffer:buf offset:0 atIndex:0];  // 记录指针，不读数据
[encoder drawPrimitives:...];                       // 命令进队，GPU 还没执行
// ... 同一个 buffer 又一次 memcpy 进新数据 ...
[encoder setVertexBuffer:buf offset:0 atIndex:0];  // 还是同一个 buffer 指针
[encoder drawPrimitives:...];
[commandBuffer commit];                             // GPU 才真正读 buffer
                                                    // → 所有 draw 都读到最后一次 upload
```

WispTerm 的 `ui_pipeline` 在一帧里反复 "upload quad verts → drawArrays"，
共享同一个 `quad` MTLBuffer。结果：N 个 fillQuad 调用，GPU 看到的是 N 次 draw
**都读最后那次 upload 的坐标**。所有 overlay panel 全部堆在最后一个 quad 的位置，
其它位置一片空白。

### 教训
- **凡是"upload + immediate draw"模式从 OpenGL 移植到 Metal，都要重新审计 buffer 生命周期**。
- Metal `setVertexBuffer:` 是 "记录指针 + 命令 buffer 持有引用直到 commit"，
  不是 "立即复制内容"。这一点 Apple 文档不算显眼，容易踩。
- 小数据（≤4KB）可以走 `setVertexBytes:length:atIndex:`，它在 call 时**就**复制 inline，
  完全避开这个坑。对 ui_pipeline 的 96 字节/quad 这条路径其实更合适。

### 修复
最简单的方案：**每次 upload 都 newBufferWithBytes**，把旧 buffer release 掉。
Metal 的 `setVertexBuffer:` 已经 retain 了旧 buffer（commit 完成才释放），所以
release 是安全的——旧 buffer 的实际 dealloc 是 GPU 完成后异步的。

```c
// bridge.m wispterm_metal_buffer_upload
@autoreleasepool {
    id<MTLBuffer> old = wispterm_metal_buffers[handle].buffer;
    id<MTLBuffer> new_buffer = wispterm_metal_new_buffer(device, bytes, len);
    if (new_buffer == nil) return false;
    wispterm_metal_buffers[handle].buffer = new_buffer;
    if (old != nil) [old release];  // command buffer 仍持有它，Metal 延迟实际释放
    return true;
}
```

每帧上百个 fillQuad → 上百次 `newBufferWithBytes:`，对小 quad（96 bytes）开销可忽略。
更优解（未实施）：每帧一个 transient arena MTLBuffer，upload 累加 offset，
`setVertexBuffer:offset:` 传 offset。Ghostty 用的就是这种方案。

---

## macOS 环境层面的坑

### 1. `[NSApp activateIgnoringOtherApps:NO]` 不会真正激活

WispTerm 的 `window_macos_bridge.m` 早期用了 `NO`。结果：
- AppKit 给 NSWindow 加了 traffic lights、设了 frontmost
- 但**键盘焦点没真正给 WispTerm**，输入跑去其它进程
- `osascript "frontmost = true"` 也只能短暂强占焦点

正确做法：`activateIgnoringOtherApps:YES`，或者用 macOS 14+ 的 `[NSApp activate:options:]`。

### 2. ToDesk / 远程控制软件拦截 keyDown:

在远程控制软件运行时，CGEventPost 合成的键盘事件会被 ToDesk 在 `keyDown:` 层拦截，
**永远不会到达** WispTerm 的 NSView。但 NSMenu 的 key equivalents 不受影响 ——
AppKit 在 `performKeyEquivalent:` 阶段处理 NSMenu，**早于** `keyDown:` 的远程控制 hook。

这意味着：
- 在有 ToDesk 的开发机上调试快捷键，要么关掉 ToDesk，要么通过 NSMenu 测
- **NSMenu 不只是 UX 加分项 —— 它是快捷键在敌对环境下唯一可靠的触发路径**
- 对最终用户：即便用户的 IME / 远程工具吃了 `Ctrl+Shift+P`，菜单点击仍然有效

### 3. 中文 IME 吞掉字母键

测试时发现 `mcp__computer-use__key text="a"` 在 WispTerm 里弹出了**拼音候选框**
("啊 阿 嗄 锕 澳")。即使 macOS 系统输入源是 "ABC"，依然可能有某个 input method
(如 macOS 自带的 PressAndHold、或第三方拼音) 在 NSTextInputClient 路径上接管。

副作用：
- "type 'echo hello' 测终端" 不会工作 —— IME 把它当成拼音输入
- 但 NSMenu / 带 Ctrl 修饰键的快捷键不进 IME，所以可以用它们做端到端测试

### 4. macOS 26 (Sequoia 后续) 上 `System Events` 的 frontmost 查询时不时挂

```
System Events 遇到一个错误：不能获得 "process 1 whose frontmost = true"。无效的索引。
```

不可重现的间歇性错误。重试通常能恢复。和我们的代码无关，但调试脚本需要兜底。

### 5. macOS 的 traffic lights 不能自己画

WispTerm Windows 端有 app-drawn titlebar + caption buttons。
macOS 上 AppKit 强制接管标题栏 + 红绿黄按钮（`NSWindowStyleMaskTitled`），
所以 WispTerm 的 app-drawn titlebar 路径在 macOS 上被禁用了
(`titlebar_height = 0`)。

后果：
- macOS 上**没有窗口内的菜单/齿轮/帮助按钮** —— 这些原本画在 app titlebar 上的
  控件全部消失（在 Windows 上汉堡菜单是入口）
- 用户只能靠键盘快捷键 → 这就是为什么 D7.1 NSMenu 是必要的
- 长期：考虑在 macOS 上把这些图标画在 AppKit titlebar 下方的窄条里

### 6. `[NSApp sendEvent:]` 是从 main thread 同步派发，threadlocal 安全

WispTerm 用了大量 `threadlocal var g_xxx` 存 UI 状态。
担心过：NSMenu 回调如果在另一个线程触发，状态不可见。

实测：AppKit 在 `[NSApp sendEvent:]` 阶段同步派发 menu action 到 main thread，
WispTerm 的渲染主循环也跑在 main thread (`first_window.run()` per App.zig:723)。
所以 menu callback 和渲染读写同一份 threadlocal storage。
**前提是新窗口创建时不要把 menu 安装挪到 spawned thread**。

---

## Zig 0.15.x 的小陷阱

### `@import` 不能走出 module root

`test-metal` 的 module root 是 `gpu/metal/test.zig`，
所以 `gpu/metal/gl_init.zig` 里 `@import("../../ui_pipeline.zig")` 会被拒：

```
error: import of file outside module path
```

App 主 build 的 module root 高（包含整个 `src/`），所以没事。

变通方案：
- **函数指针 hooks**（本 PR 用的）—— 把对方做成 register/dispatch 协议
- **build.zig 加 module 依赖** —— 让 metal_test_mod 也能看到 ui_pipeline
- **延迟 import** —— 在函数体里 `const x = @import(...)` 但**还是会被静态检查**，
  和顶层 import 同等待遇，**这条路不通**（我先试过）

### `@hasDecl` 用在 import 结果上

`AppWindow.gpu.gl_init` 是 `@import` 的结果（namespace 类型），不是值。
直接 `@hasDecl(AppWindow.gpu.gl_init, "setBackendHooks")` 即可。
`@TypeOf(gl_init)` 在这里反而是错的。

---

## 调试方法论的几点经验

### 1. "Unit tests pass but app doesn't render" 是常态

`zig build test`、`test-macos-ui`、`test-metal` 全部绿，但 app 跑起来啥都不画。
原因：unit tests 验证**逻辑**（state machine、keybind dispatch、文件 IO），
不验证**像素**。Metal stub 完全无 panic、单测正常通过，
但把"用 quad 画背景"丢进了 `_ = x;` 也合法。

防御：
- 像素级回归测试（offscreen Metal target + image diff）—— 本 PR 没做，作为下一轮 todo
- 至少 NSMenu / overlay state 改了就**手工跑 .app 看一下**

### 2. 在 ObjC bridge 里加 `fprintf(stderr, ...)` 是最快的诊断手段

`wispterm_metal_pipeline_draw_arrays` 加 fprintf 立刻看出每一帧确实有 ~200 个 draw call，
排除"没 dispatch 到 Metal" 这个假设。
**不要怕在 bridge.m 里临时加 printf**，commit 前去掉就行。

### 3. 对比 OpenGL 等价路径

每次 Metal 不对，先问：OpenGL 的 `gl_init.renderQuad` 怎么实现的？两边公共 API 哪里差异？
本 PR 的 Bug #1 就是这样发现的（OpenGL 委托给 ui_pipeline.setProjection，Metal 没委托）。

### 4. Logs 越早越好

`g_command_palette_visible` 是 threadlocal —— 在 menu callback 里 print 一下
toggle 前后的值，立刻确认 state 转变是否成功，下一步该看渲染路径。
不要陷入"我猜是 threadlocal cross-thread 问题"，先**测一下**。

---

## 这次没做但值得做的事

1. **像素回归测试**：用 offscreen `MTLTexture` 当 framebuffer 跑一帧，比对参考截图。
   能挡住 Bug #1 这种"逻辑过但视觉错"的退化。

2. **Metal frame transient buffer arena**：当前每个 ui_pipeline.fillQuad 都
   `newBufferWithBytes:`。对手游级别的 draw 数量（每帧几十）完全 OK，
   但如果引入 SSH 客户端的大文件预览或图像 grid，会变成瓶颈。
   Ghostty 的方案：单个大 MTLBuffer + 累加 offset + `setVertexBuffer:offset:`。

3. **App-drawn 状态栏 / 工具栏在 macOS 上的归宿**：Windows 端 titlebar 里的
   汉堡/齿轮/帮助图标在 macOS 上没了。考虑画在 AppKit titlebar 下方的窄条里，
   或者完全靠 NSMenu。

4. **`setVertexBytes` 改造小 buffer**：`ui_pipeline` 的 quad 数据 96 字节，
   完全适合走 `setVertexBytes`，可以省掉每次 `newBufferWithBytes` 的分配。

5. **NSMenu 项动态状态**：勾选项反映 sidebar/command-center 当前是否打开，
   快捷键文字反映用户配置的实际 keybind（不是写死的）。

---

## TL;DR

把任何"自带 OpenGL 模型的 cross-backend renderer"移植到 Metal，三个最痛的坑：

1. **Metal stub 的 no-op 看着无害但偷偷少做事** —— 必须挨个对照 OpenGL 等价路径。
2. **MTLBuffer 不是 GL buffer** —— `setVertexBuffer:` 不复制数据，`commit` 之前的所有
   buffer 修改都会被同一次 commit 看到。upload+immediate-draw 模式需要重新设计 buffer 生命周期。
3. **NSMenu 不是装饰** —— 它是在 IME/远程控制等敌对 keyDown 环境下唯一保证可达的入口。

Bonus：**Zig 0.15 的 module path 检查**让 cross-backend 委托不能用最直接的 `@import`，
需要 BackendHooks / 函数指针 / build.zig 加 module dep 之类的迂回。
