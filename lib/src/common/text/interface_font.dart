import 'lyric_font.dart';

/// 界面字体默认项的显示名（实际字体是主题里的微软雅黑 Light）。
const String kDefaultInterfaceFontLabel = '默认（微软雅黑 Light）';

/// 配置里的字体族名 → 展示名；空串是「默认」，其余与歌词字体同一套翻译
String interfaceFontLabel(String family) {
  final String name = family.trim();
  return name.isEmpty ? kDefaultInterfaceFontLabel : lyricFontLabel(name);
}

/// 配置里的字体族名 → 主题该用的 `fontFamily`；空串返回 null（用默认字体）
String? interfaceFontFamilyOrNull(String family) {
  final String name = normalizeLyricFontFamily(family);
  return name.isEmpty ? null : name;
}
