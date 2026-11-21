//! 字体枚举：读本机字体文件的 name 表，给设置页的「选择字体」弹窗用。

#[cfg(windows)]
#[test]
fn lists_installed_families() {
    let families = rust_lib_lamp_player::api::fonts::installed_font_families();
    assert!(!families.is_empty(), "Windows 上应该能扫到系统字体");
    assert!(
        families.iter().any(|name| name == "Arial"),
        "Arial 是 Windows 必带字体，扫不到说明 name 表解析有问题：{families:?}"
    );
    assert!(
        families.iter().any(|name| name == "Microsoft YaHei"),
        "中文字体也该扫到：{families:?}"
    );
    // 去重 + 排序（小写比较）后返回，Dart 侧直接列表展示
    let mut sorted = families.clone();
    sorted.sort_by_key(|name| name.to_lowercase());
    assert_eq!(sorted, families, "返回结果应按名字排序");
}
