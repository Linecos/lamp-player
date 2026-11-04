import '../../rust/api/lyrics.dart';

/// 桌面歌词的行调度：从歌词时间轴里算「当前行」和「下一次换行」。
///
/// 纯函数，不碰窗口也不碰引擎。桌面歌词窗口只在文本变化时才重绘，所以省开销的
/// 方向不是「推得多快」，而是**知道下一次换行是哪一刻**——到点推一次即可，不必
/// 靠 500ms 的位置轮询去发现换行（那最多会慢半拍）。

/// [positionMs] 处在哪一行；还没到第一行时返回 null
String? desktopLineAt(TrackLyrics lyrics, int positionMs) {
  String? line;
  for (final LyricLine item in lyrics.lines) {
    if (item.timeMs > positionMs) {
      break;
    }
    line = item.text;
  }
  return line;
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
