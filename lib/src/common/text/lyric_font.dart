import 'bundled_fonts.dart';

/// 系统字体候选：`(fontFamily, 显示名)`。
///
/// 只列 **Windows 自带或常见** 的中文字体名——这两处歌词只能按名字取系统里
/// 已安装的字体：主界面走 Flutter（DirectWrite 按 family 名解析），桌面歌词走
/// GDI+ 的 `GdipCreateFontFamilyFromName`，后者对未安装字体直接返回失败。
/// 选了没装的那款会自动降级到雅黑 UI，不会变空白。
///
/// 第一项空字符串 = 跟随界面字体（主题的「微软雅黑 Light」），也是默认值。
/// 字体族名用英文名：DirectWrite 与 GDI+ 对 `SimSun` / `Microsoft YaHei` 这类
/// 英文名都能命中，中文名（「宋体」）在部分系统语言下反而不稳。
///
/// 随安装包分发的 MiSans 不在这张表里：注册成不成功要运行时才知道，见
/// [lyricFontChoices]。
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

/// 当前真正可用的候选：跟随界面字体 → 已注册的 MiSans → 系统字体。
///
/// MiSans 只在注册成功时列出：列表里留着但选不了，会让人以为「选了没反应」。
List<(String, String)> lyricFontChoices() {
  return <(String, String)>[
    kLyricFontChoices.first,
    for (final BundledFontFace face in kMiSansFaces)
      if (registeredBundledFamilies.contains(face.family))
        (face.family, face.label),
    ...kLyricFontChoices.skip(1),
  ];
}

/// 字体族名 → 展示名；不在候选表里的原样返回
/// （用户手工改过配置、或以后加了枚举系统字体的入口时用得到）
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
/// 常规一款：存档里还是旧别名时归一成 `MiSans`，否则下拉认不出、会退回「跟随
/// 界面字体」，歌词也跟着掉回主题字体。
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
