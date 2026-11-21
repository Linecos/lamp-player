import 'bundled_fonts.dart';
import 'lyric_font.dart';

/// 界面字体默认项的显示名（实际字体是主题里的微软雅黑 Light）。
const String kDefaultInterfaceFontLabel = '默认（微软雅黑 Light）';

/// 界面字体候选：默认 → 已注册的 MiSans → 系统字体。
///
/// 与歌词字体共用那张系统字体表，只是首项换成「默认」，因为界面默认字体
/// 是主题里写死的微软雅黑 Light，而不是「跟随某个设置」。
List<(String, String)> interfaceFontChoices() {
  return <(String, String)>[
    ('', kDefaultInterfaceFontLabel),
    for (final BundledFontFace face in kMiSansFaces)
      if (registeredBundledFamilies.contains(face.family))
        (face.family, face.label),
    ...kLyricFontChoices.skip(1),
  ];
}

/// 字体族名 → 展示名；空串是「默认」，其余与歌词字体同一套翻译
String interfaceFontLabel(String family) {
  final String name = family.trim();
  return name.isEmpty ? kDefaultInterfaceFontLabel : lyricFontLabel(name);
}

/// 配置里的字体族名 → 主题该用的 `fontFamily`；空串返回 null（用默认字体）
String? interfaceFontFamilyOrNull(String family) {
  final String name = normalizeLyricFontFamily(family);
  return name.isEmpty ? null : name;
}
