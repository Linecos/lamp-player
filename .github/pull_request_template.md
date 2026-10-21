<!--
标题用中文 Conventional Commits 格式，例如：
    feat(曲库): 支持按目录增量扫描
    fix(播放器): 拖动进度条后不再回跳
一个 PR 只做一个主题；改动大请拆成多个 PR。
-->

## 改了什么

<!-- 一两句话说清；涉及界面请贴截图或 GIF -->

## 为什么

<!-- Closes #123；没有关联 issue 就写清要解决的场景 -->

## 影响范围

- [ ] Rust：`rust/src/api/{db,scan,player}.rs`、`rust/src/bass.rs`
- [ ] Flutter 界面：`lib/src/features/...`
- [ ] 应用外壳 / 主题 / 路由：`lib/src/app/`、`lib/src/theme/`
- [ ] 构建、CI、脚本、文档

## 自查

- [ ] `.\scripts\check.ps1` 通过（或分别跑过 analyze / test / format / cargo fmt / clippy）
- [ ] 本地实际跑过 `flutter run -d windows`，改动效果已验证
- [ ] 新增逻辑带了测试（Rust：`cargo test`；纯 Dart：`test/`；需原生库：`integration_test/`）
- [ ] 没有手改生成代码（`lib/src/rust/**`、`rust/src/frb_generated.rs`）；改过 Rust API 已重跑 `flutter_rust_bridge_codegen generate`
- [ ] 没有改动依赖；如有，已在下面说明并事先沟通过

## 新依赖（如有）

<!-- 名称 / 用途 / 为什么选它 / 体积与许可 -->

## 给 reviewer 的备注

<!-- 已知问题、后续待办、需要重点看的地方；没有可删本节 -->
