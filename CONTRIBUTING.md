# 贡献指南

感谢你愿意动手。Lamp Player 是一个多人协作的本地音乐播放器，**任何人都可以 fork 后提 PR**，
不需要事先成为协作者。

## 先读这三份

| 文档 | 作用 |
|---|---|
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | 分层、目录职责、数据流、扩展点 |
| [docs/API_CONTRACT.md](docs/API_CONTRACT.md) | Rust ↔ Dart 已冻结的接口；改签名要走什么流程 |
| [docs/ROADMAP.md](docs/ROADMAP.md) | 里程碑与可认领任务清单 |

## 能做点什么

- 从 ROADMAP 的**可认领任务**里挑一个，标 `good first issue` 的适合第一次上手。
- 想做清单外的东西：先开 issue 说清场景和方案，owner 确认后再动手，避免白写。
- 文档、示例、测试、复现步骤同样是有价值的贡献。

## 环境准备

系统要求：Windows 10/11（当前只支持 Windows 桌面端）。

| 依赖 | 版本 / 说明 |
|---|---|
| Flutter SDK | 3.47.0 及以上，需勾选 Windows 桌面支持（`flutter doctor` 全绿） |
| Rust | stable + MSVC 工具链（`rustup default stable-msvc`） |
| Visual Studio 2022 | 勾选「使用 C++ 的桌面开发」 |
| 开发者模式 | Windows 设置里开启（桌面插件必需） |
| PowerShell 7 | 可选，脚本在 5.1 上也能跑 |

```powershell
# 1. fork 之后 clone 你自己的仓库
git clone https://github.com/<你的用户名>/lamp-player.git
cd lamp-player
git remote add upstream https://github.com/Linecos/lamp-player.git

# 2. 一键准备（pub get + cargo fetch + 下载 BASS）
.\scripts\bootstrap.ps1

# 3. 跑起来
flutter run -d windows
```

> BASS 是闭源第三方库，不随仓库分发，由 `scripts/setup-bass.ps1` 从 un4seen 官网下载
> （BASS 本体 + flac/opus/ape/wma add-on，带 SHA256 校验）到 `third_party/bass/`
> （该目录已 gitignore）。构建时 CMake 会自动把 DLL 拷到 exe 旁；
> 没有它程序能编译，但播放会降级。
>
> Rust 装在非默认位置时，记得设置 `RUSTUP_HOME` / `CARGO_HOME`，否则 `cargo` 会报
> 「could not choose a version of cargo to run」。

## 分支与提交

**分支名**：`<type>/<简短英文或拼音>`，例如 `feat/library-list`、`fix/seek-jump`。

**提交信息**：中文 + [Conventional Commits](https://www.conventionalcommits.org/zh-hans/)。

```
<type>(<scope>): <一句话说清做了什么>
```

| type | 用途 |
|---|---|
| `feat` | 新功能 |
| `fix` | 修 bug |
| `refactor` | 重构（不改行为） |
| `perf` | 性能 |
| `docs` | 文档 |
| `test` | 测试 |
| `build` / `ci` | 构建、依赖、工作流 |
| `chore` | 杂项 |

`scope` 用模块中文名：`曲库`、`播放器`、`界面`、`构建`、`ci`……

```
feat(曲库): 支持按目录增量扫描
fix(播放器): 拖动进度条后不再回跳
docs(贡献): 补充 Rust 环境变量说明
```

要求：一句话说清做了什么，不要 `update file`；一次提交只做一件事，不要把无关改动塞进来。

## PR 流程

1. 同步最新 main：`git fetch upstream && git rebase upstream/main`
2. push 到你的 fork，向 `Linecos/lamp-player:main` 开 PR，按模板填。
3. 等 CI 四项全绿：`Flutter 分析与测试`、`Rust 检查与测试`、`Windows 桌面构建`、`frb 生成代码一致性`。
4. owner review。合并方式固定 **Create a merge commit**（不用 squash / rebase merge），合并后自动删除分支。
5. 一个 PR 只做一个主题，改动大就拆成多个 PR。

## 编码约定

**Rust**

- `cargo fmt` 与 `cargo clippy --all-targets -- -D warnings` 必须干净（CI 会卡）。
- 对外函数统一返回 `anyhow::Result<T>`；**库代码里不要 panic**，错误往上抛由 Dart 侧提示。
- 数据库访问一律走 `api::db` 的连接入口，不要在别处自己开 `Connection`。
- 平台相关代码（BASS 加载等）加 `#[cfg(target_os = "windows")]`，保持 Linux/macOS 能编译（CI 在 ubuntu 上跑）。

**Dart**

- `dart format` + `flutter analyze` 零 issue。
- 颜色、字号、圆角一律走 `Theme.of(context)`，不要在页面里写死色值；改主题只改 `lib/src/theme/app_theme.dart`。
- 新增页面：在 `lib/src/app/routes.dart` 登记常量 + 在 `switch` 里挂载，不要在别处 `Navigator.push` 硬编码字符串。
- 调用 Rust 的函数默认返回 `Future`，不要漏 `await`（lint 已开 `unawaited_futures`）。

**生成代码绝对不要手改**

`lib/src/rust/**` 与 `rust/src/frb_generated.rs` 由 `flutter_rust_bridge_codegen generate` 生成。
改了 Rust API 就重跑一次并把生成结果一起提交，否则 CI 的 `frb 生成代码一致性` 会红。

## 快捷键怎么改、怎么扩

键位表只有一处：`lib/src/features/player/shortcuts.dart`（`ShortcutAction` + `kDefaultShortcuts`）。
曲库页与正在播放页都从它生成 `CallbackShortcuts`，页面里没有任何写死的键位。

- **加一个新动作**：在 `ShortcutAction` 里加枚举值 + 在 `kDefaultShortcuts` 补默认键，
  然后在两个页面的 handlers 表里映射到具体行为。`test/features/player/shortcuts_test.dart`
  会检查动作覆盖度与组合键唯一性，漏了会红。
- **用户自定义**：设置页「快捷键」→ `ShortcutsPage` 录制组合键 → 写进
  `SessionSnapshot.shortcutsJson`。校验（冲突 / 裸键 / Tab / Esc）都在该页里。
- **换存储**：实现 `ShortcutStore`，读出来的表过一遍 `normalizeShortcuts` 兜底。
- **坑**：`SingleActivator` 没有值相等语义（`==` 比对象身份），判断「是不是同一个
  组合键」一律用 `shortcutId()`，别用 `Set<SingleActivator>`。

## 测试要求

| 改动类型 | 最低要求 |
|---|---|
| Rust 逻辑（`db` / `scan`） | `cargo test`；用例放 `rust/tests/` 或 `#[cfg(test)]` |
| 纯 Dart 逻辑 / 组件 | `test/` 下加 unit / widget 测试（**不能依赖 Rust**，否则 CI 跑不了） |
| 必须加载原生库的 | `integration_test/`：`flutter test integration_test -d windows` |

`test/` 下的用例必须能在没有 Rust 工具链的机器上通过 —— 这是 CI 的底线。

## 提交前自查

```powershell
.\scripts\check.ps1
```

等价于 CI 的全套本地检查（analyze / test / format / cargo fmt / clippy / cargo test）。
只想查一部分就加 `-SkipRust` 或 `-SkipFlutter`。

## Review 会看什么

- 改动是否只在声明范围内，有没有夹带无关的格式化或重命名；
- 错误处理：不 panic、不吞异常，界面上有 loading / 空态 / 失败重试；
- 命名与文件位置是否符合上面的约定；
- 新增依赖是否事先沟通过（`pubspec.yaml`、`Cargo.toml` 的改动请单独说明理由）；
- 有没有配套测试，或者至少在 PR 里写清怎么验证。

## 常见问题

| 现象 | 原因 / 解决 |
|---|---|
| `cargo` 报 could not choose a version | 设置 `RUSTUP_HOME`、`CARGO_HOME` 指向你的 Rust 安装位置 |
| `flutter test` 报 WebSocket upgrade 失败 | 系统代理拦截了 localhost。`scripts/check.ps1` 会自动清空 `HTTP_PROXY` / `HTTPS_PROXY` / `ALL_PROXY` 并设置 `no_proxy=localhost,127.0.0.1`；手动跑测试时要自己清。`flutter test integration_test -d windows` 同样需要 |
| 运行时提示找不到 bass.dll | 跑 `.\scripts\setup-bass.ps1`，然后重新 `flutter build/run`（构建时会把 DLL 拷到 exe 旁） |
| CI 的 frb 一致性任务红了 | 本地跑 `flutter_rust_bridge_codegen generate`，把生成文件一起提交 |
| 路径含空格构建失败 | 用 PowerShell 7 执行脚本；已按带空格路径验证过 |
