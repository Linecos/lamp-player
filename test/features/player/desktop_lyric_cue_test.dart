import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_player/src/features/player/desktop_lyric_cue.dart';
import 'package:lamp_player/src/rust/api/lyrics.dart';

TrackLyrics _lyrics(List<int> starts) {
  return TrackLyrics(
    lines: <LyricLine>[
      for (final int ms in starts)
        LyricLine(
          timeMs: ms,
          endMs: ms + 900,
          text: 'line $ms',
          words: const <LyricWord>[],
          translation: '',
        ),
    ],
    plain: '',
    source: 'sidecar',
  );
}

void main() {
  test('当前行取最近一条已过的时间戳', () {
    final TrackLyrics lyrics = _lyrics(<int>[0, 1000, 2500]);
    expect(desktopLineAt(lyrics, 0), 'line 0');
    expect(desktopLineAt(lyrics, 999), 'line 0');
    expect(desktopLineAt(lyrics, 1000), 'line 1000', reason: '正好压线时算新行');
    expect(desktopLineAt(lyrics, 2600), 'line 2500');
  });

  test('第一行之前没有当前行', () {
    final TrackLyrics lyrics = _lyrics(<int>[1500, 3000]);
    expect(desktopLineAt(lyrics, 0), isNull);
    expect(desktopLineAt(lyrics, 1499), isNull);
    expect(desktopLineAt(lyrics, 1500), 'line 1500');
  });

  test('下一次换行严格晚于当前位置', () {
    final TrackLyrics lyrics = _lyrics(<int>[0, 1000, 2500]);
    expect(nextDesktopLineStart(lyrics, 0), 1000);
    expect(nextDesktopLineStart(lyrics, 999), 1000);
    expect(
      nextDesktopLineStart(lyrics, 1000),
      2500,
      reason: '刚换到的这一行不该再被当成下一次',
    );
    expect(nextDesktopLineStart(lyrics, 2500), isNull, reason: '最后一行之后没有下一行');
    expect(nextDesktopLineStart(lyrics, 9000), isNull);
  });

  test('没有时间轴时两个函数都安全返回', () {
    const TrackLyrics empty = TrackLyrics(
      lines: <LyricLine>[],
      plain: '纯文本歌词',
      source: 'embedded',
    );
    expect(desktopLineAt(empty, 500), isNull);
    expect(nextDesktopLineStart(empty, 500), isNull);
  });
}
