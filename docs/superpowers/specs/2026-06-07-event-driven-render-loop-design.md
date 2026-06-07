# WispTerm 渲染循环 CPU 优化设计

**阶段 1:事件驱动主循环（脏门控 + 阻塞事件泵 + 后台/遮挡暂停）**

日期：2026-06-07
状态：设计已与用户对齐，待 spec 评审 → 转实现计划

---

## 1. 背景与问题

现象：WispTerm 启动后主进程 CPU 占用约 73%，**即使切到后台、被其它窗口遮挡也居高不下**。

### 已核实的根因（带证据）

主渲染循环 [AppWindow.zig:5672](../../../src/AppWindow.zig) 的 `while (running)` **每个 vsync 周期都无条件做整屏全量渲染并 present，从不判断画面是否有变化**：

- 循环里唯一的提前退出是窗口最小化时 `sleep(16ms)`（[AppWindow.zig:5761](../../../src/AppWindow.zig)），其余情况一律执行：清屏 → 画所有 cell → 画 titlebar/sidebar/scrollbar → 画一长串 overlay（[AppWindow.zig:5978-5995](../../../src/AppWindow.zig)）→ present。
- 全库搜索确认主循环内对 `dirty` 的引用只有一行注释（[AppWindow.zig:5702](../../../src/AppWindow.zig)），脏标记从未被读来跳过帧。
- 事件泵是零超时轮询：`pollEvents` → `nextEventMatchingMask:untilDate:[NSDate distantPast]`（[window_macos_bridge.m:1080](../../../src/platform/window_macos_bridge.m)），不阻塞等待。
- **为什么是 73% 而非爆 100%+**：`CAMetalLayer` 未设置 `displaySyncEnabled`，macOS 默认 `YES`（开 vsync），`nextDrawable`（[bridge.m:859](../../../src/renderer/gpu/metal/bridge.m)）在 drawable 用尽时阻塞，把帧率限制在显示器刷新率。于是它在 120Hz 屏上"老老实实每秒画 120 整帧"，占满约 0.7 个核 → 73%。**vsync 限了帧率，但没人限"该不该画"。**
- **后台/遮挡不暂停**：只检测了 `isFocused`（失焦仅触发一次重建）与 `isMinimized`，**没有 `NSWindowOcclusionState` 检测**（[AppWindow.zig:5754-5764](../../../src/AppWindow.zig)）。被其它窗口盖住但未最小化时，照样满速渲染。
- IO 线程本身已是 libxev 事件驱动（[termio/Thread.zig](../../../src/termio/Thread.zig)），不烧 CPU。**问题纯粹在主线程渲染循环。**

---

## 2. 目标与非目标

### 目标
- 聚焦且活跃时：行为与体验不变（终端输出、光标闪烁、所有 overlay 动画照常流畅）。
- 空闲（聚焦但无内容变化）：主线程 CPU 降到接近 0。
- 失焦 / 被遮挡 / 最小化 / app 后台：主线程 CPU 接近 0。
- 输入（键盘/鼠标）与终端输出：无可感知的额外延迟。

### 非目标（阶段 1 明确不做）
- 不把渲染搬到独立线程。
- 不引入 CVDisplayLink。
- 不做 per-surface 并行渲染。
- 不改"单 layer + viewport"渲染架构。

以上属于**阶段 2**（见 §8）。

---

## 3. 架构现状（决定方案的硬约束）

核实结论（带证据），这些约束直接决定了为什么阶段 1 选事件驱动而非一步到位重构：

1. **单 Context / 单 CAMetalLayer / 单 drawable**：整个窗口一个 `gpu.Context`，主线程初始化（[AppWindow.zig:5340](../../../src/AppWindow.zig)），`Handles` 仅一个 `layer` + 一个 `drawable`（[Context.zig:23-30](../../../src/renderer/gpu/metal/Context.zig)）。多 split 靠 viewport 切分，**不是** per-surface layer。
2. **GPU 渲染状态全 `threadlocal`**，且 [Context.zig:20](../../../src/renderer/gpu/metal/Context.zig) 注释明示 "rendering runs on the renderer thread" —— 作者已为"渲染上渲染线程"预埋设计（threadlocal 存储类 + [RendererThread.zig](../../../src/RendererThread.zig) 的 Phase 2 注释）。
3. **全 UI 自绘在一个主循环**：phantty 用 GPU 自绘了**全部** UI（终端 + 标题栏 + 侧栏 + 滚动条 + 文件浏览器 + Markdown 预览 + AI 面板 + 命令面板 + 设置页 + 各种 toast/确认框 + IME），这些 overlay 状态全由主线程的输入与 tick 更新。
4. `swapBuffers` 在 macOS 是 no-op（[window_backend_macos.zig:225](../../../src/platform/window_backend_macos.zig)），present 实际在 `frame_end` 的 `presentDrawable` 完成。

**关键推论**：因为第 1 + 第 3 条，把渲染搬到线程（阶段 2）意味着几乎所有 UI 状态都要变成线程安全，跨线程同步面远大于 Ghostty —— 这是真正的大手术。而降 CPU 这个原始目标，阶段 1 在主线程内即可达成。

---

## 4. 方案决策

### 候选方案对比

| 方案 | 形态 | 空闲/后台效果 | 改动 / 风险 |
|---|---|---|---|
| 1 脏门控补丁 | 单线程 + sleep 轮询节流 | 空闲个位数%、后台近 0 | 集中主循环，低 |
| **2 事件驱动（选定）** | 单线程 + 阻塞等事件 + 跨线程唤醒 | 空闲/后台**真 0** | 中等 |
| 3 完整 Ghostty 化 | 渲染上线程 + CVDisplayLink | 最优（含 vsync 对齐） | 大重构 + 全 UI 状态跨线程同步，高 |

### 决策：分两阶段
- **阶段 1 = 方案 2**（本文档）。
- **阶段 2 = 方案 3**，作为独立的架构演进项目后续立项（见 §8）。

### 理由
- 降 CPU 目标方案 2 即可完全达成（空闲/后台真 0），且无需触碰跨线程 UI 状态同步。
- 方案 3 相对方案 2 的额外收益（渲染脱离主线程、vsync 对齐更顺滑）是**架构演进价值，不是当前痛点**；在 phantty 的"单 layer + 全 UI 自绘"约束下，其代价/回归风险与降 CPU 目标不成比例。
- 方案 2 是方案 3 的**前置地基**（事件驱动 + 变化来源收口 + occlusion 桥接都可复用），先做方案 2 不浪费。

---

## 5. 阶段 1 详细设计

### 可行性验证结论（go）
- **阻塞事件泵已存在**：`pumpAppEvents(timeout)` 底层即 `nextEventMatchingMask:untilDate:until`（[window_macos_bridge.m:1101-1120](../../../src/platform/window_macos_bridge.m)），真正阻塞等事件到超时。
- **唯一缺口 = 跨线程唤醒**：当前 PTY/IO 线程只 `surface.dirty.store(true)`（[ReadThread.zig:119](../../../src/termio/ReadThread.zig)、[termio/Thread.zig:172](../../../src/termio/Thread.zig)），靠主线程轮询。无 `postEvent`/application-defined event 机制。需新增。

### 6 个核心机制

#### M1. 阻塞事件泵替代零超时轮询
主循环判定"本帧无需渲染"（见 M3）时，改用带超时的事件等待（复用 `pumpAppEvents` 的 `nextEventMatchingMask:untilDate:` 模式）阻塞，直到来事件或超时。聚焦且活跃时仍走快速渲染路径，体验不变。
- 改动：`AppWindow.zig` 主循环；可能复用/抽出 `window_macos.zig` 的带超时泵。

#### M2. 跨线程唤醒（新增 `post_wakeup`）
新增 C 函数（`window_macos_bridge.m`）：从任意线程 `[NSApp postEvent:atStart:]` 一个 application-defined `NSEvent`，让阻塞在 `nextEventMatchingMask` 的主线程立即返回。
- 调用点：PTY/IO 线程标 `surface.dirty` 后；AI 流式回包；其它后台→UI 通知。
- 暴露为 `window_backend` 接口，供 Zig 侧跨线程调用。

#### M3. 保守脏门控 `frameNeedsRender()`（关键设计决策）
新增判定函数，采用 **"白名单进入省电"** 策略：**只有当全部活跃信号静默时才阻塞跳帧；任何不确定都倾向渲染**。这样"漏判一个来源导致画面卡住"的风险被结构性消除（漏判最坏只是多画，不会少画）。
- 判定为"需要渲染"的信号见 §6 变化来源清单。
- 改动：`AppWindow.zig` 新增 `frameNeedsRender()`；逐步把散落的 `g_force_rebuild`/`g_cells_valid` 等收口到统一的 `markNeedsRender()` 语义（为阶段 2 的 wakeup 入口铺路）。

#### M4. 超时驱动定时性工作
阻塞超时 = `min(距下次光标翻转, 距下次必须执行的 tick, 分级上限)`。
- 分级上限（初始默认，可在评审中调整）：聚焦 ~100ms / 失焦可见 ~250ms / 遮挡·最小化·后台 ~500ms。
- 光标闪烁由超时自然驱动，**不需要单独 NSTimer**。
- 改动：`AppWindow.zig` 主循环超时计算。

#### M5. occlusion / focus 检测（独立桥接，阶段 2 复用）
新增 `window_is_visible()` 读 `NSWindow.occlusionState.contains(.visible)`（一个信号同时覆盖遮挡/最小化/后台，与 Ghostty 一致）。
- 失焦/遮挡时：拉长 M4 的超时上限；失焦时停止光标闪烁（符合 macOS 习惯，并省一个唤醒源）。
- **刻意做成干净独立模块**：`window_macos_bridge.m` 桥接 + `window_backend` 接口，阶段 2 上 CVDisplayLink 时直接用它来 `start/stop`。

#### M6. 定时 tick 周期保证
主循环开头那批 tick（[AppWindow.zig:5674-5683](../../../src/AppWindow.zig)：config watcher、session launcher、file explorer async、markdown async、ai_loop_store、update/skill check 等）靠 M4 的超时上限保证至少每 ≤500ms 执行一次；报告"有变化"的 tick（如 `markdown_preview_panel.tickAsync()` 返回 true）设脏触发渲染。

---

## 6. 变化来源清单（脏门控输入）

`frameNeedsRender()` 须在以下任一信号活跃时返回"需要渲染"。**实现前需用代码搜索逐条核全**（本清单为已知主项，宁多勿漏）：

| 类别 | 信号 | 当前是否已有可门控标记 |
|---|---|---|
| 终端内容 | 任一 `surface.dirty`（PTY 输出） | 有（atomic bool） |
| 光标闪烁 | 到达 600ms 翻转点 | 有（时间戳计算） |
| 强制重建 | `g_force_rebuild` / `!g_cells_valid` | 有 |
| 字体图集 | `font.g_atlas_modified` 等 | 有 |
| 窗口状态 | resize 待处理 / focus 变化 / dpi 变化 | 部分有（多置 g_force_rebuild） |
| Overlay/面板 | 命令面板、设置页、文件浏览器、Markdown 预览、AI 面板、session launcher、各 toast、确认框、whats-new、IME preedit、debug/fps overlay 处于**打开或动画态** | **门控盲区，多数无统一"活动态"查询，需新增** |
| AI 流式 | AI 回复流式打字、loop/watch 任务进行中 | 待核实 |
| 异步 tick | 各 `tickAsync`/`tick` 报告有变化 | 部分有返回值（如 markdown），部分无 |

**门控盲区**（overlay 活动态、AI 流式、部分 tick）是实现重点：要么为每个活动态提供查询函数，要么让其在活动期间持续 `markNeedsRender()`（粗粒度但安全）。

---

## 7. 风险与缓解

- **漏判变化来源 → 画面卡住**：① 保守白名单（不确定就画）；② M4 分级超时上限兜底——即便全静默，也每 ≤500ms 醒来重新评估；③ 可选"最大不渲染间隔"做最终保险（默认开，如 1s，权衡极小 CPU 换绝对不卡）。
- **输入延迟**：postEvent + NSEvent 唤醒即时，无额外延迟。
- **后台命令仍要刷新**：PTY 输出经 M2 唤醒主循环，后台运行的程序输出照常更新，只是不再空转。

---

## 8. 范围边界

### 阶段 1 做
M1–M6，全部在主线程内；不碰渲染线程、不碰跨线程 UI 状态同步。

### 阶段 1 不做（留给阶段 2）
渲染上单一窗口级渲染线程 + CVDisplayLink 驱动 + 失焦/遮挡 `stop` link。

### 阶段 2 可复用阶段 1 的资产
- M5 的 occlusion/focus 桥接（直接驱动 display link start/stop）。
- M3 的脏门控逻辑（迁入渲染线程的 `drawFrame`，对应 Ghostty 的 `needs_redraw`）。
- 变化来源收口的 `markNeedsRender()`（对应 Ghostty 的 `queueRender → wakeup.notify`）。

---

## 9. 实现前待核实项

- **多窗口主循环交互**：[App.zig:852/961](../../../src/App.zig) 支持多 window，每个 `run()` 是阻塞循环；postEvent 是 app 级唤醒。需在 plan 阶段确认多窗口下阻塞/唤醒的正确性，可能影响主循环改造细节。

---

## 10. 验收标准

- 空闲（聚焦、终端无输出、无 overlay）：CPU 降到极低（个位数%）。注：光标闪烁仍会每 600ms 唤醒画一帧，故非绝对 0；这是预期，失焦停闪或关闭光标闪烁可进一步到 0。
- 失焦 / 遮挡 / 最小化 / 后台：光标停闪、无唤醒源，主进程 CPU ≈ 0。
- 终端持续输出（如 `yes`、`htop`）：渲染正常，CPU 与输出量相称。
- 光标闪烁、所有 overlay 动画/打字机/toast 淡出：正常不卡顿、不掉帧。
- 键盘/鼠标输入：无可感知延迟。
- 测量手段：活动监视器 / `top` 对比改造前后；必要时加帧计数日志验证空闲时不再 present。
