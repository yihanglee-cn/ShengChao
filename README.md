# 声潮 ShengChao

> 液态玻璃（Liquid Glass）风格的原生 macOS 无损音乐播放器

声潮是一款用 **SwiftUI + AVFoundation** 编写的 macOS 本地音乐播放器，主打无损播放、macOS 26 液态玻璃视觉，以及**动态封面 / 3D 封面**等特色功能。

---

## ✨ 主要功能

### 播放
- 🎵 **无损播放**：FLAC / ALAC / WAV / AIFF / CAF / MP3 / AAC / M4A 等格式
- 📀 **整轨 CUE 分轨**：自动按 CUE 展开分轨曲目（支持 GBK/GB18030 编码的 CUE 文件）
- 🔄 **自动切歌**、可拖动进度条、音量调节
- 📊 **实时音频信息**：正在播放栏实时显示采样率、位深、码率（如 `44.1 kHz · 24 bit · 1289 kbps`）
- 🔊 任意声道/采样率文件统一经 AVAudioConverter 逐块转换播放，稳定不爆音

### 封面
- 🖼 **动态封面**：专辑文件夹中的 `cover.mp4` 自动识别，播放时显示动态封面（悬浮窗、播放栏、大封面共享一个播放器，进度同步）
- 🧊 **3D 封面**：内置 Depth Anything V2 深度估计模型（ONNX），为每张封面生成独立深度图；大封面模式下**鼠标在屏幕任意位置移动即驱动 3D 视差**，前景浮起、背景分离
  - 深度图自动缓存到专辑文件夹（`cover3d_depth_v2.png`），下次打开秒读，无需重复计算
  - 与动态封面开关互斥；节能模式下自动关闭
- 🏷 **FLAC 内嵌封面/标签**：完整读取内嵌封面与标签信息

### 歌词
- 📝 **自动下载歌词**：右键专辑封面 →「添加歌词…」，从 lrclib.net 自动匹配下载
- 🧩 **整轨拼接**：CUE 整轨专辑自动逐曲下载并按时间轴拼接（支持繁简/标点归一化匹配）
- ⌨️ 快捷键 **L** 随时开关歌词面板

### 界面
- 🧊 **液态玻璃界面**：macOS 26 Liquid Glass 视觉，夜晚/白天双主题一键切换
- 🚀 **启动动画**：全屏背景 + 波形 logo + 主界面交叉淡入
- 🪟 **全局悬浮窗**：随时置顶的小播放器（动态封面、hover 红点关闭按钮）
- 🗂 **完整曲库视图**：专辑 / 艺术家 / 歌曲 / 收藏 / 最近播放 / 播放列表
- 🎚 **智能排序**：曲目按 CUE 偏移 > trackNumber > 文件名数字 > 标题排序

### 节能
- 🔋 **节能模式**：设置中开启后自动关闭 3D 封面，降低资源占用

---

## ⌨️ 快捷键

| 按键 | 功能 |
|---|---|
| `空格` | 播放 / 暂停 |
| `←` / `→` | 上一首 / 下一首 |
| `↑` / `↓` | 音量加减 |
| `L` | 显示 / 隐藏歌词 |
| `Z` | 打开 / 关闭大封面 |

---

## 📦 安装方法

### 方式一：DMG 安装包（推荐）

1. 下载 `声潮-x.x.x.x.dmg`
2. 打开 DMG，把「声潮」拖入 **Applications** 文件夹
3. 首次打开如遇 Gatekeeper 提示，**右键点击 app → 打开**（应用为 ad-hoc 签名）

### 方式二：源码构建

```bash
# 需要 macOS 26 SDK + Xcode Command Line Tools
cd LiquidGlassPlayer
./build.sh        # 编译并同步产物到桌面 声潮.app 与 /Applications/声潮.app
./make_dmg.sh     # 打包生成 DMG
```

> 构建产物：`build/声潮.app`，同时自动部署到 `~/Desktop/声潮.app` 与 `/Applications/声潮.app`。

---

## 🚀 使用方法

1. **添加曲库**：启动后点侧边栏「专辑」→ 选择音乐文件夹（支持外置硬盘/网络卷）
2. **播放**：双击任意曲目，或点播放按钮；双击专辑可整张播放
3. **查看专辑**：点侧边栏切换「专辑 / 艺术家 / 歌曲 / 最近播放 / 收藏 / 播放列表」
4. **大封面**：点击播放栏左下角封面（快捷键 `Z`）——大封面模式下：
   - 开启「3D 封面」后，移动鼠标（全屏范围）封面随视差立体变化
   - 开启「动态封面」后，显示 cover.mp4 动态效果
5. **歌词**：右键专辑封面 →「添加歌词…」，播放时按 `L` 显示
6. **设置**：右上角齿轮（⚙️）——节能模式 / 动态封面 / 3D 封面开关

---

## 💻 支持的系统版本

| 项目 | 要求 |
|---|---|
| macOS | **macOS 26（Tahoe）及以上**（使用 macOS 26 液态玻璃 API） |
| 芯片 | **Apple Silicon（arm64）** |
| 音频格式 | FLAC / ALAC / WAV / AIFF / CAF / MP3 / AAC / M4A 等 |

---

## 🗂 项目结构

```
LiquidGlassPlayer/
├── Sources/
│   ├── LiquidGlassPlayerApp.swift   # App 入口（含设置窗口）
│   ├── ContentView.swift            # 主界面（侧边栏/播放栏/大封面/设置）
│   ├── AudioLibrary.swift           # 曲库扫描/播放引擎/CUE 解析/歌词下载
│   ├── DepthEngine.swift            # 3D 封面深度推理（ONNX）
│   ├── ParallaxCoverView.swift      # 3D 视差渲染（Core Image）
│   ├── SplashView.swift             # 启动动画
│   ├── FloatingPlayerView.swift     # 全局悬浮窗
│   ├── Lyrics.swift                 # 歌词解析
│   ├── ort_bridge.c / bridge.h      # ONNX Runtime C 桥接层
├── vendor/                          # ONNX Runtime 动态库与头文件、深度模型
├── assets/                          # 图标等资源
├── build.sh                         # 构建脚本
└── make_dmg.sh                      # DMG 打包脚本
```

## 📄 许可证

- 声潮本体：**MIT License**（见 [LICENSE](LICENSE)）
- 深度模型：[Depth Anything V2](https://github.com/DepthAnything/Depth-Anything-V2)（MIT License）
- 运行时：[ONNX Runtime](https://github.com/microsoft/onnxruntime)（MIT License）
- 歌词数据：[lrclib.net](https://lrclib.net)（免费 API）
