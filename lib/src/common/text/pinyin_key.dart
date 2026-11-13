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

/// 单字缓存：汉字 → 拼音（无调）。
///
/// 曲库里不同的汉字通常只有一两千个，而曲目上万条 —— 逐条调用 `getPinyin`
/// 的绝大多数开销都是同一个字的重复查询。缓存到字一级之后，一条标题只剩
/// 几次 map 查找：一万条中文标题首次建键 101ms，再排一次只要 4ms。
///
/// 只缓存到「字」这一层，不缓存整串：整串缓存要多存几万条字符串，还得考虑
/// 什么时候清，收益只有几毫秒。
final Map<int, String> _charPinyinCache = <int, String>{};

String _pinyinOfRune(int rune) => _charPinyinCache.putIfAbsent(rune, () {
  final String char = String.fromCharCode(rune);
  try {
    // 与 [buildPinyinKey] 用同一个默认格式（无调），两边结果才对得上
    final String pinyin = PinyinHelper.getPinyin(char, separator: ' ');
    return pinyin.isEmpty ? char : pinyin.replaceAll(' ', '');
  } catch (_) {
    // 生僻字：宁可排不准，也不要抛异常
    return char;
  }
});

/// 生成用于**按拼音排序**的键：汉字转全拼（无调、无分隔），
/// 其余字符转小写后原样保留。
///
/// 和 [buildPinyinKey] 的区别是只保留全拼、不长成 `全拼|首字母`：
/// 比较大小用不上首字母，多拼一段只是白算。
///
/// 这样中英混排也能落到同一把尺子上 —— 「玻璃海」是 `bolihai`，
/// 「Blue Archive」是 `blue archive`，按 `b` 打头一起排。
String pinyinSortKey(String text) {
  final StringBuffer buffer = StringBuffer();
  for (final int rune in text.runes) {
    if (rune >= 0x4E00 && rune <= 0x9FFF) {
      buffer.write(_pinyinOfRune(rune));
    } else {
      buffer.write(String.fromCharCode(rune).toLowerCase());
    }
  }
  return buffer.toString();
}
