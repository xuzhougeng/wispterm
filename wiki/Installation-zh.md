# 安装

*[English](Installation) · 中文*

> 在 Windows、macOS 或实验性 Linux 上下载运行 WispTerm，或从源码构建。

WispTerm 提供 **Windows** 与 **macOS** 版本。**Linux** x86_64 AppImage 也会作为社区测试
版本发布，仍属实验性质。

## Windows

1. 从 [GitHub Releases](https://github.com/xuzhougeng/wispterm/releases) 下载最新
   Windows 版本。
2. 把整个压缩包解压到一个文件夹。
3. 运行 **`wispterm.exe`**，或双击 **`Replace-WispTerm.cmd`**：脚本会按开始菜单
   快捷方式覆盖现有安装；如果还没有快捷方式，则安装到
   `%LOCALAPPDATA%\Programs\WispTerm` 并创建开始菜单项。

WispTerm 不会自行提权 —— 普通方式启动得到的是标准权限令牌。需要管理员 shell 时，
右键 `wispterm.exe` 选择 **以管理员身份运行**（见 [[常见问题|FAQ-zh]]）。

**便携配置（仅 Windows）：** 在 `wispterm.exe` 旁放一个名为 `wispterm.conf` 的文件，
WispTerm 就会用它作为配置，整套设置可随 U 盘或共享目录携带。

## macOS

需要 **macOS 13+**。下载与你 CPU 对应的 `.app`（Apple Silicon 或 Intel），移动到
`/Applications`。

- 正常双击启动 **`WispTerm.app`**，**或**
- 直接运行二进制以传入 CLI 参数：
  ```bash
  WispTerm.app/Contents/MacOS/WispTerm --version
  ```

> 传入命令行选项必须用二进制路径 —— 双击 `.app` 无法附带参数。

## Linux（实验性）

下载 `WispTerm-*-x86_64.AppImage` release asset，赋予可执行权限后运行：

```bash
chmod +x WispTerm-*-x86_64.AppImage
./WispTerm-*-x86_64.AppImage
```

如果系统没有 FUSE 支持，可加 `--appimage-extract-and-run`。Linux 构建内置 SDL3，主要用于
社区测试，尚不视为稳定版本。

## 从源码构建

需要 **Zig 0.15.2**。

Windows（PowerShell）：

```powershell
zig build                         # 开发用 Debug 构建
zig build -Doptimize=ReleaseFast  # 发布用 ReleaseFast 构建
```

macOS：

```bash
zig build macos-app -Dtarget=aarch64-macos   # Apple Silicon（Intel 用 x86_64-macos）
open zig-out/bin/WispTerm.app
```

完整的构建、打包与发布细节见
[`docs/development.md`](https://github.com/xuzhougeng/wispterm/blob/main/docs/development.md)。

## 验证安装

```bash
wispterm --version            # 打印 WispTerm 版本
wispterm --show-config-path   # 打印解析出的配置文件路径
```

## 保持更新

默认情况下，WispTerm 会在启动后不久检查
[GitHub Releases](https://github.com/xuzhougeng/wispterm/releases)，发现新版本时弹出
可点击的提示。设 `auto-update-check = false` 可关闭。你也可以从
[[命令中心|Getting-Started-zh]]按需更新：

- **Check for Updates** —— 立即检查是否有新版本。
- **Download Update** —— 把最新版本下载到 Downloads 文件夹。
- **Open Latest Release** —— 在浏览器中打开发布页。

在 Windows 上，解压后双击 **`Replace-WispTerm.cmd`** 即可覆盖开始菜单里的现有安装。

升级后，**What's New**（命令中心里，也会在首次启动新版本时自动弹出）会汇总改动。
**Skill Center（技能中心）** 可以盘点、安装并跨服务器同步技能，也能从 GitHub 仓库安装最新技能。

下一步：**[[快速上手|Getting-Started-zh]]**。

---
*另见：[[快速上手|Getting-Started-zh]] · [[配置|Configuration-zh]]*
