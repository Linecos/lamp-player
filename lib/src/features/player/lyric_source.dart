/// 一首歌的歌词来源。
///
/// 目前两种：同目录同名旁载文件、音频文件里的内嵌标签。两者都有歌词时按
/// 用户排的顺序取第一个能用的（设置页 →「歌词来源优先级」）。
enum LyricSource {
  sidecar(id: 'sidecar', title: '旁载歌词', detail: '同名 .lrc / .ttml 文件'),
  embedded(id: 'embedded', title: '内嵌歌词', detail: '写在音频文件的标签里');

  const LyricSource({
    required this.id,
    required this.title,
    required this.detail,
  });

  /// 存档里的标识；与 Rust 侧 `source` 用的是同一套词
  final String id;

  /// 设置页 / 弹窗里的名字
  final String title;

  /// 名字下面那句说明
  final String detail;

  static LyricSource? fromId(String id) {
    for (final LyricSource source in LyricSource.values) {
      if (source.id == id) {
        return source;
      }
    }
    return null;
  }
}

/// 默认顺序：旁载优先于内嵌
const List<LyricSource> lyricSourceOrderDefault = <LyricSource>[
  LyricSource.sidecar,
  LyricSource.embedded,
];

/// 把存档里的 id 还原成一条完整顺序。
///
/// 存档可能缺失、可能混进丢弃过的旧来源：认识的按原顺序留下，缺的补到末尾，
/// 不认识的一律丢掉——顺序一定要覆盖全部来源，否则「排完序」也可能读不到歌词。
List<LyricSource> lyricSourceOrderFromIds(List<String>? ids) {
  final List<LyricSource> order = <LyricSource>[];
  for (final String id in ids ?? const <String>[]) {
    final LyricSource? source = LyricSource.fromId(id);
    if (source != null && !order.contains(source)) {
      order.add(source);
    }
  }
  for (final LyricSource source in LyricSource.values) {
    if (!order.contains(source)) {
      order.add(source);
    }
  }
  return order;
}

/// 存进会话的 id 列表
List<String> lyricSourceOrderIds(List<LyricSource> order) => <String>[
  for (final LyricSource source in order) source.id,
];

/// 这次读歌词要不要先试内嵌（Rust `lyrics_load` 的 `embedded_first`）
bool embeddedFirstIn(List<LyricSource> order) =>
    order.isNotEmpty && order.first == LyricSource.embedded;
