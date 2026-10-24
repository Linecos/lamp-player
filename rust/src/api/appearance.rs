//! 外观：读取系统强调色，供「跟随系统」动态取色使用。
//!
//! 非 Windows 或读取失败时返回 `None`；调用方回落默认种子色即可，
//! 这不是错误——动态取色只是可选项。

/// 系统强调色（0xAARRGGBB）；设置页「跟随系统强调色」用
#[flutter_rust_bridge::frb(sync)]
pub fn system_accent_color() -> Option<u32> {
    crate::appearance::accent_color()
}
