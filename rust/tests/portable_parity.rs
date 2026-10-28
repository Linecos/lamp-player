//! 两个平台实现的公开接口必须一一对应。
//!
//! 开发机几乎都在 Windows 上，`cargo check` 只会编译 `bass/windows.rs`；
//! `bass/portable.rs` 少了函数要等 CI 的 ubuntu job 才炸
//! （2026-10-28 就漏了 `set_replay_gain`，main 直接红）。
//! 这里做一次源码级的对照，本地跑 `cargo test` 就能拦住同类问题。

use std::collections::BTreeSet;

/// 顶层 `pub fn` 的名字集合（缩进即非顶层，impl 里的方法不会混进来）
fn top_level_pub_fns(source: &str) -> BTreeSet<&str> {
    source
        .lines()
        .filter_map(|line| {
            let rest = line.strip_prefix("pub fn ")?;
            let name = rest.split(['(', '<']).next()?.trim();
            (!name.is_empty()).then_some(name)
        })
        .collect()
}

#[test]
fn portable_and_windows_expose_the_same_functions() {
    let windows = top_level_pub_fns(include_str!("../src/bass/windows.rs"));
    let portable = top_level_pub_fns(include_str!("../src/bass/portable.rs"));

    let only_windows: Vec<&&str> = windows.difference(&portable).collect();
    let only_portable: Vec<&&str> = portable.difference(&windows).collect();

    assert!(
        only_windows.is_empty(),
        "portable.rs 缺少这些 Windows 侧函数（Linux CI 会编译失败）：{only_windows:?}"
    );
    assert!(
        only_portable.is_empty(),
        "windows.rs 缺少这些便携侧函数：{only_portable:?}"
    );
    assert!(
        !windows.is_empty() && !portable.is_empty(),
        "解析结果为空，说明源码结构变了，请更新这个测试"
    );
}
