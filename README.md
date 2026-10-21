# Lamp Player 🎵

基于 **Flutter + Rust + BASS** 的本地音乐播放器。

## 特性

- 🎨 Material 3 界面（Flutter），自适应主题
- 🦀 Rust 负责核心逻辑：音乐文件扫描、元数据解析、系统集成
- ⚡ BASS 底层音频解码，低延迟输出
- 🗄️ SQLite 曲库存储，支持 **FTS5 全文检索**（歌名/歌手/专辑即时搜索）
- 🖥️ 首先支持 Windows，后续可扩展 Android / Linux

## 架构

```
┌─────────────────────────────┐
│   Flutter (Material 3 UI)   │  界面、交互、播放列表
└──────────────┬──────────────┘
               │ flutter_rust_bridge (类型安全 FFI)
┌──────────────▼──────────────┐
│          Rust Core          │
│  ├─ scanner   文件扫描       │
│  ├─ metadata  标签解析(lofty)│
│  ├─ db        SQLite+FTS5   │
│  └─ player    BASS 播放引擎  │
└──────────────┬──────────────┘
               │ FFI
┌──────────────▼──────────────┐
│     BASS (bass.dll)         │  解码 / 混音 / 低延迟输出
└─────────────────────────────┘
```

## 技术栈

| 层 | 技术 |
|---|---|
| 界面 | Flutter 3.x + Material 3 |
| 桥接 | flutter_rust_bridge v2 |
| 扫描/元数据 | Rust + `walkdir` / `lofty` |
| 曲库 | `rusqlite`（bundled SQLite + FTS5） |
| 音频 | [BASS](https://www.un4seen.com/) 2.4 |

## 开始使用

### 前置要求

- Flutter SDK（含 Windows 桌面支持）
- Rust 工具链（MSVC）
- Visual Studio 2022 及 C++ 构建工具

### 1. 准备 Rust 环境

```bash
flutter pub get
flutter_rust_bridge_codegen generate   # 首次运行前安装：cargo install flutter_rust_bridge_codegen
```

### 2. 下载 BASS 库

BASS 为闭源第三方库，不随仓库分发，运行脚本自动下载：

```powershell
.\scripts\setup-bass.ps1
```

### 3. 构建运行

```bash
flutter run -d windows
```

## 目录结构

```
├── lib/            Flutter 界面与业务逻辑
├── rust/           Rust 核心（扫描、元数据、曲库、播放）
├── windows/        Windows 宿主工程
├── scripts/        辅助脚本（BASS 下载等）
├── third_party/    第三方二进制（BASS，不入库）
└── bridge/         flutter_rust_bridge 生成的绑定
```

## 许可证

本项目代码以 [MIT](LICENSE) 许可发布。

注意：BASS 音频库由 [Un4seen Developments](https://www.un4seen.com/) 版权所有，采用其自有许可（非商用免费），与本项目的 MIT 许可相互独立。
