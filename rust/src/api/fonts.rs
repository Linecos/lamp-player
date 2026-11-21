/// 本机已安装的字体族名（设置页「选择字体」弹窗用）
///
/// 结果按名字排序、已在 Rust 侧缓存；第一次调用会扫 `%WINDIR%\Fonts` 与
/// `%LOCALAPPDATA%\Microsoft\Windows\Fonts`，之后直接返回。
#[flutter_rust_bridge::frb]
pub fn installed_font_families() -> Vec<String> {
    crate::system_fonts::installed_families()
}
