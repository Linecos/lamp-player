import 'package:pinyin/pinyin.dart';

/// 判断字符串里是否有汉字（有汉字时拼音匹配没有意义，FTS 已经能命中）。
bool hasCjk(String text) {
  for (final int rune in text.runes) {
    if (rune >= 0x4E00 && rune <= 0x9FFF) {
      return true;
    }
  }
  return false;
}

/// 生成用于搜索的拼音键：`全拼|首字母`。
///
/// - 汉字转拼音（不带声调），英文 / 数字原样保留并转小写；
/// - 只对汉字片段调 `getPinyin`，避免 `getPinyinE` 对无法转换的字符打印日志；
/// - 转换失败（生僻字）时保留原文：宁可搜不到，也不要抛异常。
String buildPinyinKey(String text) {
  final StringBuffer full = StringBuffer();
  final StringBuffer short = StringBuffer();
  final StringBuffer pending = StringBuffer();

  void flushPending() {
    if (pending.isEmpty) {
      return;
    }
    final String chunk = pending.toString();
    pending.clear();
    try {
      final List<String> words = PinyinHelper.getPinyin(
        chunk,
        separator: ' ',
      ).split(' ').where((String word) => word.isNotEmpty).toList();
      full.write(words.join());
      short.write(words.map((String word) => word[0]).join());
    } catch (_) {
      full.write(chunk);
      short.write(chunk);
    }
  }

  for (final int rune in text.runes) {
    final String char = String.fromCharCode(rune);
    if (rune >= 0x4E00 && rune <= 0x9FFF) {
      pending.write(char);
      continue;
    }
    flushPending();
    final String lowered = char.toLowerCase();
    full.write(lowered);
    short.write(lowered);
  }
  flushPending();

  return '${full.toString()}|${short.toString()}';
}

/// 把查询规范成可与 [buildPinyinKey] 结果比较的形式（去空白、转小写）。
String normalizePinyinQuery(String query) =>
    query.replaceAll(RegExp(r'\s+'), '').toLowerCase();
