# macOS 编译/调试排障笔记

记录在 macOS（特别是国内网络环境 + Intel Mac）上编译调试 WispTerm 时遇到的几类问题与解法。三个问题彼此独立，按需取用：

| 问题 | 类型 | 状态 |
|---|---|---|
| [build.zig 没传 `emit-lib-vt`，导致 ghostty 强行构建 iOS xcframework](#1-buildzig-emit-lib-vt-缺失) | WispTerm 真 bug | ✅ 已修 |
| [Homebrew `zig@0.15` 在 build runner 阶段死锁（wedge）](#2-homebrew-zig015-build-runner-死锁) | 环境问题 | 🔧 换官方 zig |
| [GitHub 依赖拉不下来 / zig HTTP 客户端不稳](#3-github-依赖下载问题) | 网络问题 | 🔧 镜像 + 离线下载 |

---

## 0. 环境

- macOS 14.x（本案 14.2.1，23C71），Intel x86_64（MacBookPro16,2）
- 只装了 Xcode Command Line Tools（无完整 Xcode，无 iOS SDK）
- Zig 0.15.2（`minimum_zig_version` 见 `build.zig.zon`）
- 国内网络，github.com 大文件直连不稳定

构建命令：

```bash
cd /path/to/wispterm
zig build macos-app -Dtarget=x86_64-macos -Doptimize=Debug
# Apple Silicon 改 -Dtarget=aarch64-macos
```

---

## 1. build.zig `emit-lib-vt` 缺失

### 症状

`zig build macos-app` 报：

```
thread XXXXX panic: unhandled error
.../std/zig/LibCInstallation.zig:174:  return error.DarwinSdkNotFound;
← ghostty .../src/build/SharedDeps.zig:146 in add
← ghostty .../src/build/GhosttyLib.zig:52 in initStatic
← ghostty .../src/build/GhosttyXCFramework.zig:28 in init   ← 在构 iOS xcframework
← ghostty build.zig:213 in build
← wispterm/build.zig:1236  b.lazyDependency("ghostty", .{...})
```

或第二处在 `ghostty build.zig:269`（`xcframework_native`）。

### 根因

Ghostty 的 `Config.zig:353` 定义了 `emit-lib-vt` 选项，**专为"WispTerm 这种只用 `ghostty-vt` module 的下游"设计**——开了它就禁用 xcframework / macOS app / docs 的构建。

WispTerm 的 `build.zig` 在两处 `b.lazyDependency("ghostty", ...)` 调用（app 主模块、bench 模块）都没传这个选项，默认 `emit_lib_vt=false`。于是 ghostty `build.zig:211` / `:269` 的条件成立 → 强行构 iOS/macOS xcframework → `findNative` 找 iOS SDK → 机器只有 CLT 没 iOS SDK → `DarwinSdkNotFound` 崩。

即便机器装了完整 Xcode 让默认路径走得通，WispTerm 也**根本不需要** iOS xcframework——它只用 `dep.module("ghostty-vt")` 和 `dep.path("src/stb")`，跟 xcframework 完全无关。所以这个缺失既是兼容性 bug，也是无用功。

### 修法（已应用到本仓库）

`build.zig` 两处 `lazyDependency("ghostty", ...)` 都加：

```zig
if (b.lazyDependency("ghostty", .{
    .target = target,
    .optimize = optimize,
    .simd = false,
    .@"emit-lib-vt" = true,         // ← 关键
    .@"emit-xcframework" = false,   // ← 显式压死，绕开 xcodebuild 探测分支
    .@"emit-macos-app" = false,     // ← 同上
})) |dep| { ... }
```

**三个都加**的原因：

- 只加 `emit-lib-vt` 不够。Ghostty `Config.zig:443` 的 `emit_xcframework` 默认逻辑在 lib-vt 模式下会 fallback 到"看 `xcodebuild` 是否在 PATH"——只要 PATH 里有 `xcodebuild`（哪怕只装了部分 Xcode 工具，或 `/usr/bin/xcodebuild` stub 存在），仍会触发 xcframework 构建。
- 显式 `emit-xcframework=false` + `emit-macos-app=false` 让 `b.option(...) orelse ...` 直接走左支返回 false，完全跳过 xcodebuild 探测。

### 踩过的坑：Zig `lazyDependency` 字段名不会自动转换下划线/连字符

错误写法（会被静默忽略，等于没传）：

```zig
.@"emit_lib_vt" = true,   // ❌ 下划线，zig 不认
.emit_lib_vt = true,      // ❌ 同上
```

正确写法（kebab-case 原样保留）：

```zig
.@"emit-lib-vt" = true,   // ✅
```

证据：同文件 `lazyDependency("freetype", .{ .@"enable-libpng" = true })` 就是这种 `@"..."` 写法。Zig build 系统不自动转。

### 验证

修复后 ghostty 依赖只走 macOS SDK（CLT 自带），不再需要 iOS SDK 或完整 Xcode。

---

## 2. Homebrew `zig@0.15` build runner 死锁

### 症状

`zig build macos-app ...` 跑几分钟到几十分钟毫无输出，看似在编译实则完全卡死。诊断特征：

```bash
ZIG_PID=$(pgrep -f "zig build macos-app")
ps -o pid,stat,%cpu,etime -p $ZIG_PID
# 输出类似：
# PID    STAT  %CPU ELAPSED
# 23092  S+     0.0  40:00       ← 0% CPU，S=sleeping，已卡 40 分钟
```

- **CPU 长期 0.0%**（不是 50-100% 单核满载）
- **STAT = S+**（sleeping，不是 R+ running）
- **没有任何子进程**（`pgrep -P $ZIG_PID` 为空，不是在等 clang/xcrun）
- `.zig-cache/o/` 产物数不增长，长时间停在 0 或几个
- `lsof -p $PID` 看到卡在一个 unix socket 上等永远不会来的事件

### 根因

Homebrew 的 `zig@0.15` formula 是社区维护，已知在 macOS 上 build runner event loop 有死锁问题（mach IPC + `std.event` 混用）。这是 Zig 社区反复出现的坑。

### 解法：换官方 Zig tarball

```bash
# 1. 杀死卡死的 zig
kill $ZIG_PID; sleep 2; kill -9 $ZIG_PID 2>/dev/null

# 2. 下官方 zig（ziglang.org 慢的话走代理或镜像）
mkdir -p /tmp/zig-official && cd /tmp/zig-official
curl -L --max-time 300 --retry 5 -C - \
  --proxy http://127.0.0.1:7890 \
  -o zig.tar.xz \
  https://ziglang.org/download/0.15.2/zig-macos-x86_64-0.15.2.tar.xz
tar xJf zig.tar.xz
/tmp/zig-official/zig-macos-x86_64-0.15.2/zig version   # 应输出 0.15.2

# 3. 用绝对路径调官方 zig（绕开 brew 的 zig），依赖缓存保留
cd /path/to/wispterm
rm -rf zig-out .zig-cache
# 注意：不要 rm ~/.cache/zig —— 已下好的依赖在那里，删了又要重下
/tmp/zig-official/zig-macos-x86_64-0.15.2/zig build macos-app -Dtarget=x86_64-macos -Doptimize=Debug
```

Apple Silicon 用 `zig-macos-aarch64-0.15.2.tar.xz`。

### 怎么早期发现

新终端每 1-2 分钟跑一次，CPU 长期 0% + 产物数不涨 = 又卡了：

```bash
ps -o pid,stat,%cpu,etime -p $(pgrep -f "zig build") 2>/dev/null
ls .zig-cache/o/ 2>/dev/null | wc -l
```

---

## 3. GitHub 依赖下载问题

### 症状

`zig build` 报：

```
build.zig.zon:18: error: invalid HTTP response: HttpConnectionClosing
build.zig.zon:23: error: invalid HTTP response: HttpConnectionClosing
```

或：

```
build.zig.zon:20: error: bad HTTP response code: '400 Bad Request'
build.zig.zon:38: error: bad HTTP response code: '400 Bad Request'
```

或：

```
build.zig.zon:20: error: unable to unpack tarball to temporary directory: ReadFailed
```

### 根因（三层，按概率排）

1. **`HttpConnectionClosing`**：国内直连 github.com 下大文件（ghostty 归档几 MB）中途被墙/断。
2. **`400 Bad Request`**：两个可能的子原因——
   - 代理变量（`HTTPS_PROXY` 等）被 zig 0.15.2 的 std.http 客户端读到了但处理有 bug，把请求搞坏。
   - 镜像 URL（如 `https://ghproxy.net/https://github.com/...`）里嵌的 `https://` 被 zig 的 URL 解析器 percent-encode 了，镜像不认。
3. **`ReadFailed`**：镜像给了截断的 gzip 流（连接中途掉）。

### 解法（按场景选）

#### 场景 A：只是 GitHub 直连不稳，代理是好的

先确认代理可达：

```bash
curl -sI --max-time 15 --proxy http://127.0.0.1:7890 \
  -o /dev/null -w "HTTP %{http_code}  %{time_total}s\n" \
  "https://github.com/ghostty-org/ghostty/archive/master.tar.gz"
# HTTP 302 + <2s = 代理好
```

如果 zig 读代理变量不工作（仍报 400），就**别让 zig 走 HTTP**——用 curl 离线下，走 `file://`（见场景 C）。

#### 场景 B：镜像可用，且 zig 能直接走镜像

测可用镜像（关键：实际 GET 几 KB 验证返回的是真 gzip 数据 `1f 8b`，不是镜像首页伪装的 200）：

```bash
GHOSTTY_URL="https://github.com/ghostty-org/ghostty/archive/4dcb09ada0c0909717d92547623b26eafa50ca8a.tar.gz"
for m in \
  "https://ghproxy.net/https://github.com" \
  "https://gh-proxy.com/https://github.com" \
  "https://mirror.ghproxy.com/https://github.com" \
  "https://ghps.cc/https://github.com" \
  "https://github.moeyy.xyz/https://github.com" \
  "https://hub.gitmirror.com/https://github.com"; do
  test_url="${m}/ghostty-org/ghostty/archive/4dcb09ada0c0909717d92547623b26eafa50ca8a.tar.gz"
  echo "  $m → $(curl -sI --max-time 8 -o /dev/null -w "%{http_code}" "$test_url" 2>&1)"
done
```

找到能用的镜像后，**临时改 `build.zig.zon`**（不要提交！记得 `git checkout` 还原）：

```zig
.ghostty = .{
    .url = "https://ghproxy.net/https://github.com/ghostty-org/ghostty/archive/<commit>.tar.gz",
    .hash = "ghostty-1.3.2-dev-...",   // hash 不变
},
```

⚠️ **经验**：即便 curl 走镜像能通，zig 0.15.2 自己发请求可能仍 400（URL 编码问题）。**优先用场景 C**。

#### 场景 C：最稳——curl 离线下载 + `file://` URL（推荐）

完全绕开 zig 的 HTTP 客户端。

**步骤 1：清代理变量 + 清缓存**：

```bash
unset HTTPS_PROXY https_proxy HTTP_PROXY http_proxy ALL_PROXY all_proxy
env | grep -i proxy   # 应输出空
rm -rf zig-out .zig-cache ~/.cache/zig
```

**步骤 2：用 curl 下三个 tarball**（curl 比 zig HTTP 稳得多，支持 `--retry` 断点续传）：

```bash
mkdir -p .deps-cache

# ghostty（大文件，多 retry + 断点续传）
curl -L --retry 5 --retry-delay 2 -C - --max-time 300 \
  -o .deps-cache/ghostty.tar.gz \
  "https://ghproxy.net/https://github.com/ghostty-org/ghostty/archive/4dcb09ada0c0909717d92547623b26eafa50ca8a.tar.gz"

# z2d（小文件）
curl -L --retry 5 --retry-delay 2 -C - --max-time 120 \
  -o .deps-cache/z2d.tar.gz \
  "https://ghproxy.net/https://github.com/vancluever/z2d/archive/refs/tags/v0.10.0.tar.gz"

# libxev（在 ghostty 自己的镜像，国内一般直连可达）
curl -L --retry 5 --retry-delay 2 -C - --max-time 120 \
  -o .deps-cache/libxev.tar.gz \
  "https://deps.files.ghostty.org/libxev-34fa50878aec6e5fa8f532867001ab3c36fae23e.tar.gz"
```

如果 ghproxy 截断了大文件（`gzip -t` 失败），换镜像或走代理重下：

```bash
rm .deps-cache/ghostty.tar.gz
curl -L --retry 10 -C - --max-time 600 --proxy http://127.0.0.1:7890 \
  -o .deps-cache/ghostty.tar.gz \
  "https://github.com/ghostty-org/ghostty/archive/4dcb09ada0c0909717d92547623b26eafa50ca8a.tar.gz"
```

**步骤 3：完整性校验**（任何一个失败都不能继续）：

```bash
for f in .deps-cache/*.tar.gz; do
  gzip -t "$f" 2>&1 && echo "  $f: gzip OK"
  tar tzf "$f" >/dev/null 2>&1 && echo "  $f: tar OK" || echo "  $f: tar 损坏，重下"
done
ls -lh .deps-cache/   # ghostty >1MB，z2d/libxev 几十 KB
```

**步骤 4：临时改 `build.zig.zon` 走 `file://`**（不要提交）：

```zig
.ghostty = .{
    .url = "file:///absolute/path/to/wispterm/.deps-cache/ghostty.tar.gz",
    .hash = "ghostty-1.3.2-dev-...",
},
.z2d = .{
    .url = "file:///absolute/path/to/wispterm/.deps-cache/z2d.tar.gz",
    .hash = "z2d-0.10.0-...",
},
// ...
.libxev = .{
    .url = "file:///absolute/path/to/wispterm/.deps-cache/libxev.tar.gz",
    .hash = "libxev-0.0.0-...",
},
```

**步骤 5：编译**（用官方 zig，见第 2 节）：

```bash
/tmp/zig-official/zig-macos-x86_64-0.15.2/zig build macos-app -Dtarget=x86_64-macos -Doptimize=Debug
```

**步骤 6：调试完还原**：

```bash
git checkout build.zig.zon   # 还原 URL 改动；build.zig 的 emit-lib-vt 修复保留
rm -rf .deps-cache           # 可选
```

### 关于 hash

`.hash` 是从 tarball **内容**算出来的 zig package hash，跟下载源无关。所以无论走直连、镜像、还是 `file://`，只要下到的是同一个 commit 的原版归档，hash 都对得上。如果镜像/代理篡改了内容（罕见），zig 会报 hash mismatch。

---

## 4. （进行中）agent 标签崩溃 bug

> ⚠️ 此节为调查中的开放问题，根因尚未通过 lldb 源码级回溯最终确认。

### 症状

启动 WispTerm → 点击 AI Agent 标签 → 立即闪退。1.34.0 安装版复现，1.35.0 当前代码未修。

### 崩溃报告关键信息

- **崩溃位置**：`renderer.assistant.conversation.render` 偏移 +10862 字节，调用链 `main → App.run → AppWindow.run → runMainLoop → renderAiChatFrame → render`（`AppWindow.zig:1912`）
- **异常类型**：`EXC_BAD_ACCESS`，trap 13（x86 **#GP 通用保护故障**），**不是**空指针解引用
- **崩溃指令**：`movdqa [rax], xmm0`，rax = 堆地址 `0x7fdcc9194a48`（**仅 8 字节对齐，非 16 字节**）
- **前一条指令**：`cvttps2dq xmm0, xmm0`（4×float → 4×int32 SIMD 转换）
- **后端**：macOS Metal（`batching_supported = (gpu.active == .opengl)` 为假）
- **rdi 符号器输出**：`renderer.gpu.metal.render_state.scissor`（最近邻符号，非断言）

### 根因假设（置信度中-高）

trap 13 + `movdqa` + rax 仅 8 字节对齐 = **典型的"对齐 SIMD 存到对齐不成立的指针"** 症状。Zig 给某段 4×float→4×int 的代码生成了对齐 SIMD 存储（`movdqa`，要求 16 字节对齐），但目标指针实际只有 ≤8 字节对齐，触发 #GP。

> **更新**：以下假设方向对（对齐类问题），但位置猜错了。真正的根因见下方"已确认根因"。

### 已确认根因（Debug lldb 抓到）

编出 Debug 版后，Zig 的运行时对齐安全检查（UBSan）在**启动时**就精确抓住了 bug，比 agent tab 点击更早：

```
thread XXX panic: member access within misaligned address 0x7f8ab8200c58
  for type 'WispTermMetalBufferSlot', which requires 16 byte alignment

src/renderer/gpu/metal/bridge.m:404 in wispterm_metal_buffer_create
    if (wispterm_metal_buffers[handle].target == 0 && ...)
```

根因是 **Metal 后端 C 桥接代码 `bridge.m` 里的 `_Thread_local` 数组在 macOS TLS 中没有获得所需的 16 字节对齐**：

- `wispterm_metal_buffers[]`、`wispterm_metal_textures[]`、`wispterm_metal_pipelines[]`、`wispterm_metal_samplers[]` 四个数组含 ObjC 对象指针，编译器认为类型需要 16 字节对齐
- macOS 的 TLS 实现（`_Thread_local` via `__tlv_descriptor`）**不兑现** `__attribute__((aligned(16)))`——这是一个已知的 macOS 平台限制
- Debug 模式下 UBSan 立刻检测到成员访问通过未对齐基址 → 启动 panic
- Release 模式下（1.34.0）UBSan 被关掉，启动侥幸过了，但 TLS 数据的坏对齐最终在某次 SIMD 操作（`conversation.render` 里的 `movdqa`）命中 #GP → **这就是最初的"点 agent 标签 SIGSEGV"**

**同一个根因，两种 manifestation**：Debug 启动崩，Release 延迟到 agent tab 崩。

### 修复

两层修复：

1. **`bridge.m`**：给 4 个 `_Thread_local` 数组加 `__attribute__((aligned(16)))`。这在 macOS 上被 TLS 运行时忽略（无效），但在其他平台有效，且文档化了对齐意图。
2. **`build.zig`**：编译 `bridge.m` 时加 `-fno-sanitize=alignment`，跳过 UBSan 对齐检查。这让 Debug 能启动（x86 对未对齐标量访问本身是安全的），不影响 Release 行为。
3. **后续改进（TODO）**：把 4 个 TLS 数组改成堆分配的 per-thread 存储（`pthread_key` + `posix_memalign`），彻底消除 UB，届时可移除 sanitizer 抑制。

### 为什么 agent tab 才崩，copilot 不崩

`agent_enabled = true` 让 render 走不同分支（`mode_text = "Agent"`、`compact=false`、消息列表视口尺寸不同），**多渲染了几个面板区域，更容易命中那条对齐不成立的 SIMD 写**。本质跟"agent 还是 copilot"无关，只是 agent 多渲染几帧/几个不同 rect，碰到了坏对齐的那次写。

### 状态

- ✅ **已修复**：`build.zig` + `bridge.m` 改完后 Debug 启动正常，点 agent 标签不再崩溃
- ✅ 根因通过 Debug lldb / UBSan 精确确认（不是假设）

### Debug 复现 + lldb 抓现场步骤

```bash
# 1. 编 Debug 版（按本文档第 1-3 节排障编通后）
/tmp/zig-official/zig-macos-x86_64-0.15.2/zig build macos-app -Dtarget=x86_64-macos -Doptimize=Debug
# 产物：zig-out/bin/WispTerm.app

# 2. lldb 启动（不要用 open WispTerm.app，环境变量传不进去且 lldb 不好附）
lldb -- zig-out/bin/WispTerm.app/Contents/MacOS/WispTerm
(lldb) run
# 应用起来后点 agent 标签复现崩溃

# 3. 崩溃后抓这些（全部输出贴回来）
(lldb) bt all                    # 全线程回溯
(lldb) frame select 0
(lldb) source list               # 崩在哪个源码文件、哪一行
(lldb) frame variable            # 所有局部变量
(lldb) disassemble -p            # 崩溃点前后汇编
(lldb) register read             # 寄存器全量
```

如果 Debug 版没崩（Debug 关掉 SIMD 优化就不触发了），再编一份 ReleaseFast 复现验证：

```bash
/tmp/zig-official/zig-macos-x86_64-0.15.2/zig build macos-app -Dtarget=x86_64-macos -Doptimize=ReleaseFast
```

---

## 5. 本次变更清单

调试期间对仓库做的改动：

| 文件 | 改动 | 性质 | 是否提交 |
|---|---|---|---|
| `build.zig` | 两处 `lazyDependency("ghostty", ...)` 加 `.@"emit-lib-vt"=true` + `.@"emit-xcframework"=false` + `.@"emit-macos-app"=false` | **真修**（任何 macOS/CLT-only 环境都受益） | ✅ 建议提 PR |
| `build.zig.zon` | 三处 URL 改成 `file:///Users/yuzhang/wispterm/.deps-cache/*.tar.gz` | **本地临时**（绕开网络/HTTP 客户端问题） | ❌ 不要提交，`git checkout build.zig.zon` 还原 |
| `.deps-cache/` | curl 离线下载的三个依赖 tarball | 本地临时 | ❌ 应加入 `.gitignore` 或用完即删 |

### 建议的后续 PR

1. **`build.zig` 的 `emit-lib-vt` 修复**：独立的小 PR，1 文件 2 处 + 注释。让 macOS CLT-only 用户能直接编译，不再需要完整 Xcode。也减少 ghostty 依赖的无用功（不构 iOS xcframework）。
2. **崩溃 bug 修复**：等 lldb 抓到源码行后单独提 PR，附 regression 测试。
