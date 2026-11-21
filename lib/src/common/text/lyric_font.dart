import 'bundled_fonts.dart';

/// 内置中文字体表：`(fontFamily, 中文名)`。
///
/// 只用来做两件事：把族名翻成中文显示、给弹窗搜索提供中文别名。真正可选的
/// 字体来自本机枚举（`systemFonts`），那张表比这里全得多。
///
/// 空串那项是歌词字体的默认值「跟随界面字体」；界面字体的默认项另有一份说明
/// （见 `interface_font.dart` 的 `kDefaultInterfaceFontLabel`）。
const List<(String, String)> kLyricFontChoices = <(String, String)>[
  ('', '跟随界面字体'),
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

/// 字体族名 → 展示名；不在内置表里的原样返回（本机字体大多都是这一类）
///
/// 已下线的 MiSans 字重别名（`MiSans Light` 等）按同一款显示：存档里留着旧名
/// 时，界面上不该冒出一个英文家族名。
String lyricFontLabel(String family) {
  for (final BundledFontFace face in kMiSansFaces) {
    if (face.family == family) {
      return face.label;
    }
  }
  if (isBundledMiSansFamily(family)) {
    return kMiSansFaces.first.label;
  }
  for (final (String value, String label) in kLyricFontChoices) {
    if (value == family) {
      return label;
    }
  }
  return family.isEmpty ? kLyricFontChoices.first.$2 : family;
}

/// 存档 / 配置里的字体族名 → 现在能用的家族名
///
/// 早先随包发过 MiSans 的四个字重（Light / Regular / Medium / Bold），现在只留
/// 常规一款：存档里还是旧别名时归一成 `MiSans`，否则弹窗认不出当前项、歌词也
/// 会跟着掉回主题字体。
///
/// 字体没下载（家族没注册）时原样返回，交给调用方按「未知值」处理。
String normalizeLyricFontFamily(String family) {
  final String name = family.trim();
  if (name.isEmpty || !isBundledMiSansFamily(name)) {
    return name;
  }
  for (final BundledFontFace face in kMiSansFaces) {
    if (registeredBundledFamilies.contains(face.family)) {
      return face.family;
    }
  }
  return name;
}

/// 配置里的字体族名 → 主界面歌词该用的 `fontFamily`；空串返回 null（继承主题）
String? lyricFontFamilyOrNull(String family) {
  final String name = normalizeLyricFontFamily(family);
  return name.isEmpty ? null : name;
}
