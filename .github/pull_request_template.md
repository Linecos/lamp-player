<!-- 标题请用中文 Conventional Commits 格式，例如：
     feat(播放条): 音量滑块支持拖动
     fix(曲库): 修正重复文件误入库
     一个 PR 只包含一个主题的改动。 -->

## 改动内容

<!-- 一句话概括 + 需要 reviewers 注意的地方 -->

## 关联 Issue

<!-- 如有，填 issue 链接；没有可删本节 -->

## 自查清单

- [ ] `flutter analyze` / `cargo check` 通过（按改动范围）
- [ ] 已在本地实际验证改动效果
- [ ] 没有手改 `frb_generated.*`（改了就跑 `flutter_rust_bridge_codegen generate` 重新生成）
- [ ] 没有改 `pubspec.yaml` / `Cargo.toml` 依赖（有新依赖请在下面说明并先和 owner 沟通）

## 新依赖（如有）

<!-- 简述用途与选择理由 -->
