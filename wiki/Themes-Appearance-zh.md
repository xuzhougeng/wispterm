# 主题与外观

*[English](Themes-Appearance) · 中文*

> 选择主题、设置字体与光标、添加背景图，以及应用 GLSL 着色器。

## 主题

WispTerm 内置 **453 款兼容 Ghostty 的主题**（默认：**Poimandres**）。按名称或绝对
路径设置：

```text
theme = Poimandres
```

用 `wispterm --list-themes` 列出，或在 <https://phantty.cc-remote.app/themes.html>
浏览主题画廊。主题文件采用 Ghostty 主题格式，因此任何 Ghostty 主题文件都可直接使用。

## 字体

```text
font-family = Cascadia Code
font-style = medium
font-size = 14
```

- `font-family` —— 任意已安装字体；留空则用内置回退字体。
- `font-style` —— `thin`、`extra-light`、`light`、`regular`、`medium`、
  `semi-bold`、`bold`、`extra-bold`、`black`。
- `font-size` —— 磅。

用 `wispterm --list-fonts` 列出可用字体。WispTerm 做**逐字形回退**：所选字体里缺失的
字符（例如 CJK 字形）会自动用回退字体绘制。

## 光标

```text
cursor-style = bar          # block | bar | underline | block_hollow
cursor-style-blink = true
```

## 背景图

在终端背后渲染壁纸。支持 PNG、JPG、BMP、GIF、TGA。

```text
background-image = C:\Users\me\Pictures\wallpaper.png
background-opacity = 0.85
background-image-mode = fill
```

`background-opacity` 控制主题背景对壁纸的色调覆盖强度：

| 值 | 效果 |
| --- | --- |
| `1.0`（默认） | 主题背景完全不透明；图片被遮住 |
| `0.85` | 淡淡的水印（图片透出约 15%） |
| `0.5` | 等比混合 |
| `0.15` | 图片为主，叠一层淡淡主题色 |
| `0.0` | 跳过主题色调；图片满强度 |

该不透明度同样作用于逐单元格背景（选区、ANSI 着色背景），因此壁纸会以相同比例透出。

`background-image-mode` 决定图片如何适配窗口：

| 模式 | 行为 |
| --- | --- |
| `fill`（默认） | 覆盖窗口，裁掉较长一边 |
| `fit` | 加黑边，使整张图都可见 |
| `center` | 1:1 像素比例，居中 |
| `tile` | 按原始尺寸平铺 |

## 自定义着色器

```text
custom-shader = path/to/shader.glsl
```

应用兼容 Ghostty 的 GLSL 后处理着色器。壁纸在后处理帧缓冲内绘制，因此自定义着色器会把
背景图与终端内容一起扭曲处理。

---
*另见：[[配置|Configuration-zh]] · [[内联图片|Inline-Images-zh]]*
