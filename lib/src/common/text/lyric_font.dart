import 'bundled_fonts.dart';

/// 歌词字体候选：`(fontFamily, 显示名)`。
///
/// 只列 **Windows 自带或常见** 的中文字体名——两处歌词都只能按名字取系统里
/// 已安装的字体：主界面走 Flutter（DirectWrite 按 family 名解析），桌面歌词走
/// GDI+ 的 `GdipCreateFontFamilyFromName`，后者对未安装字体直接返回失败。
/// 所以这里不打包任何字体，选了没装的那款会自动降级到雅黑 UI，不会变空白。
///
/// 第一项空字符串 = 跟随界面字体（主题的「微软雅黑 Light」），也是默认值。
/// 字体族名用英文名：DirectWrite 与 GDI+ 对 `SimSun` / `Microsoft YaHei` 这类
/// 英文名都能命中，中文名（「宋体」）在部分系统语言下反而不稳。
const List<(String, String)> kLyricFontChoices = <(String, String)>[
  ('', '跟随界面字体'),
  // 随安装包分发（scripts/setup-misans.ps1）：「MiSans」这个名字是运行时用
  // FontLoader 注册进去的家族名，不是系统字体名
  (miSansFamily, 'MiSans（小米）'),
  ('Microsoft YaHei Light', '微软雅黑 Light'),
  ('Microsoft YaHei', '微软雅黑'),
  ('Microsoft YaHei UI', '微软雅黑 UI'),
  ('SimSun', '宋体'),
  ('SimHei', '黑体'),
  ('DengXian', '等线'),
  ('KaiTi', '楷体'),
  ('FangSong', '仿宋'),
  ('STKaiti', '华文楷体'),
  ('STSong', '华文宋体'),
];

/// 字体族名 → 展示名；不在候选表里的原样返回
/// （用户手工改过配置、或以后加了枚举系统字体的入口时用得到）
String lyricFontLabel(String family) {
  for (final (String value, String label) in kLyricFontChoices) {
    if (value == family) {
      return label;
    }
  }
  return family.isEmpty ? kLyricFontChoices.first.$2 : family;
}

/// 配置里的字体族名 → 主界面歌词该用的 `fontFamily`；空串返回 null（继承主题）
String? lyricFontFamilyOrNull(String family) =>
    family.trim().isEmpty ? null : family.trim();

/// 当前真正可用的候选：MiSans 只有在字体包加载成功时才出现。
///
/// 列表里留着它但选不了会让人以为「选了没反应」，所以缺字体时直接不显示。
List<(String, String)> lyricFontChoices() {
  return kLyricFontChoices
      .where(
        ((String, String) item) => item.$1 != miSansFamily || misansAvailable,
      )
      .toList(growable: false);
}
