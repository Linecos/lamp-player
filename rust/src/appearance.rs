//! 系统强调色读取（MD3 动态取色的数据源）。
//!
//! 放在 `api` 之外：`api/` 下的每个 `pub fn` 都会被 frb 当作导出接口，
//! 平台实现里的同名函数会造成重复绑定，所以实现层单独成模块。
//!
//! Windows 上读的是「个性化 → 颜色 → 强调色」，与资源管理器、任务栏同源；
//! 非 Windows 或读取失败时返回 `None`，Dart 侧回落默认种子色。

/// 系统强调色（0xAARRGGBB）；读不到时 `None`
#[cfg(windows)]
pub fn accent_color() -> Option<u32> {
    use windows::Win32::System::Com::{CoInitializeEx, COINIT_MULTITHREADED};
    use windows::UI::ViewManagement::{UIColorType, UISettings};

    // WinRT 激活要求线程已初始化 COM，而 frb 的调用落在线程池；
    // 已初始化时返回 S_FALSE / RPC_E_CHANGED_MODE，忽略即可（与 smtc.rs 同理）
    unsafe {
        let _ = CoInitializeEx(None, COINIT_MULTITHREADED);
    }

    let settings = UISettings::new().ok()?;
    let color = settings.GetColorValue(UIColorType::Accent).ok()?;
    let (a, r, g, b) = (
        u32::from(color.A),
        u32::from(color.R),
        u32::from(color.G),
        u32::from(color.B),
    );
    Some((a << 24) | (r << 16) | (g << 8) | b)
}

#[cfg(not(windows))]
pub fn accent_color() -> Option<u32> {
    None
}
