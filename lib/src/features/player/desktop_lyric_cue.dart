import '../../rust/api/lyrics.dart';

/// 桌面歌词的行调度：从歌词时间轴里算「当前行」和「下一次换行」。
///
/// 纯函数，不碰窗口也不碰引擎。桌面歌词窗口只在文本变化时才重绘，所以省开销的
/// 方向不是「推得多快」，而是**知道下一次换行是哪一刻**——到点推一次即可，不必
/// 靠 500ms 的位置轮询去发现换行（那最多会慢半拍）。

/// [positionMs] 处在第几行；还没到第一行时返回 -1
int desktopLineIndexAt(TrackLyrics lyrics, int positionMs) {
  int index = -1;
  for (int i = 0; i < lyrics.lines.length; i += 1) {
    if (lyrics.lines[i].timeMs > positionMs) {
      break;
    }
    index = i;
  }
  return index;
}

/// [positionMs] 处在哪一行；还没到第一行时返回 null
String? desktopLineAt(TrackLyrics lyrics, int positionMs) {
  final int index = desktopLineIndexAt(lyrics, positionMs);
  return index < 0 ? null : lyrics.lines[index].text;
}

/// 严格晚于 [positionMs] 的第一行开始时刻（毫秒）；已经是最后一行则返回 null
int? nextDesktopLineStart(TrackLyrics lyrics, int positionMs) {
  for (final LyricLine item in lyrics.lines) {
    if (item.timeMs > positionMs) {
      return item.timeMs.toInt();
    }
  }
  return null;
}

/// 本行已经唱到整行宽度的多少（0..1），用来给桌面歌词做逐字裁切。
///
/// 和正在播放页同一个算法：每个字占 `weights[i]` 的宽度，字内按「到下一个字的
/// 时间」线性推进；唱完的部分整块计入，正在唱的那个字按比例计入。
/// `lineEndMs` 是最后一个字的结束时间。
double karaokeFillRatio({
  required List<int> times,
  required List<double> weights,
  required int lineEndMs,
  required double positionMs,
}) {
  if (times.isEmpty || weights.length != times.length) {
    return 1;
  }
  double total = 0;
  for (final double weight in weights) {
    total += weight;
  }
  if (total <= 0) {
    return 1;
  }
  double filled = 0;
  for (int i = 0; i < times.length; i += 1) {
    final double start = times[i].toDouble();
    if (positionMs <= start) {
      break;
    }
    final double next = i + 1 < times.length
        ? times[i + 1].toDouble()
        : lineEndMs.toDouble();
    final double progress = next <= start
        ? 1
        : ((positionMs - start) / (next - start)).clamp(0.0, 1.0);
    filled += weights[i] * progress;
    if (progress < 1) {
      break;
    }
  }
  return (filled / total).clamp(0.0, 1.0);
}
