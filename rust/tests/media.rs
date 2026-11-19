//! 系统集成（SMTC / 单实例）的真机测试。
//!
//! 需要 Windows 桌面会话；SMTC 在精简系统或被策略禁用时会失败，此时跳过，
//! 不把 CI 弄红。测试结束会清空系统浮层，不留残余。

use rust_lib_lamp_player::api::media::{
    media_clear, media_init, media_is_supported, media_set_play_mode, media_set_state,
    media_set_track, single_instance_acquire, MediaPlayState, MediaRepeatMode,
};

#[test]
fn smtc_reports_metadata_and_state() {
    if !media_is_supported() {
        eprintln!("跳过：当前平台没有 SMTC");
        return;
    }
    if let Err(error) = media_init() {
        eprintln!("跳过：SMTC 不可用（{error}）");
        return;
    }
    // 二次初始化必须幂等
    media_init().expect("重复初始化应成功");

    media_set_track(
        "夜航".to_string(),
        "林间电台".to_string(),
        "夜航".to_string(),
        None,
    )
    .expect("更新元数据应成功");

    media_set_state(MediaPlayState::Playing).expect("设置播放中应成功");
    media_set_state(MediaPlayState::Paused).expect("设置暂停应成功");
    media_set_state(MediaPlayState::Stopped).expect("设置停止应成功");

    media_clear().expect("清理应成功");
}

#[test]
fn smtc_accepts_cover_file() {
    if !media_is_supported() {
        return;
    }
    if media_init().is_err() {
        return;
    }
    // 1×1 透明 PNG
    const PNG: &[u8] = &[
        0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44,
        0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x06, 0x00, 0x00, 0x00, 0x1f,
        0x15, 0xc4, 0x89, 0x00, 0x00, 0x00, 0x0d, 0x49, 0x44, 0x41, 0x54, 0x78, 0xda, 0x63, 0xfc,
        0xcf, 0xc0, 0x50, 0x0f, 0x00, 0x04, 0x85, 0x01, 0x80, 0x84, 0xa9, 0x8c, 0x21, 0x00, 0x00,
        0x00, 0x00, 0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82,
    ];
    let cover = std::env::temp_dir().join("lamp_smtc_cover.png");
    std::fs::write(&cover, PNG).expect("写入测试封面");

    media_set_track(
        "封面测试".to_string(),
        "测试".to_string(),
        "封面".to_string(),
        Some(cover.to_string_lossy().into_owned()),
    )
    .expect("带封面的元数据应成功");

    // 封面路径不存在时必须退化为纯文字，而不是报错
    media_set_track(
        "封面测试".to_string(),
        "测试".to_string(),
        "封面".to_string(),
        Some(cover.with_extension("gone").to_string_lossy().into_owned()),
    )
    .expect("封面缺失时不应失败");

    media_clear().ok();
    let _ = std::fs::remove_file(cover);
}

#[test]
fn smtc_accepts_play_mode() {
    if !media_is_supported() {
        return;
    }
    if media_init().is_err() {
        return;
    }
    // 三档循环都要能上报：Windows 只有收到过 AutoRepeatMode 才会点亮浮层按钮
    for repeat in [
        MediaRepeatMode::Off,
        MediaRepeatMode::All,
        MediaRepeatMode::One,
    ] {
        media_set_play_mode(repeat, false).expect("设置循环模式应成功");
    }
    media_set_play_mode(MediaRepeatMode::All, true).expect("设置随机应成功");
    media_set_play_mode(MediaRepeatMode::Off, false).expect("复位应成功");
    // 三个事件（按钮 / 循环 / 随机）能在真机上注册成功：注册失败的话浮层里
    // 点按钮不会有任何回调，这里直接把它变成红。
    // `smtc` 模块只在 Windows 编译，非 Windows 上整块跳过
    #[cfg(windows)]
    rust_lib_lamp_player::smtc::listen(|_| {}).expect("注册系统事件应成功");
    media_clear().ok();
}

#[test]
fn single_instance_acquire_is_idempotent() {
    if !cfg!(windows) {
        return;
    }
    let acquired = single_instance_acquire().expect("申请单实例失败");
    if !acquired {
        // 本机正开着 Lamp Player 时，互斥体被它持有：跳过而不是误报失败
        eprintln!("跳过：已有 Lamp Player 实例在运行");
        return;
    }
    assert!(
        single_instance_acquire().expect("重复申请失败"),
        "同一进程重复申请仍应返回 true"
    );
}
