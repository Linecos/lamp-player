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

TrackLyrics _lyricsWithTranslations(
  List<int> starts,
  List<String> translations,
) {
  return TrackLyrics(
    lines: <LyricLine>[
      for (int i = 0; i < starts.length; i += 1)
        LyricLine(
          timeMs: starts[i],
          endMs: starts[i] + 900,
          text: 'line ${starts[i]}',
          words: const <LyricWord>[],
          translation: i < translations.length ? translations[i] : '',
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

  test('逐字进度按字宽推进，唱完即 1', () {
    const List<int> times = <int>[0, 1000, 2000];
    const List<double> weights = <double>[10, 10, 10];

    double ratio(double ms) => karaokeFillRatio(
      times: times,
      weights: weights,
      lineEndMs: 3000,
      positionMs: ms,
    );

    expect(ratio(0), 0);
    expect(ratio(500), closeTo(1 / 6, 1e-9));
    expect(ratio(1000), closeTo(1 / 3, 1e-9), reason: '刚唱完第一个字');
    expect(ratio(2000), closeTo(2 / 3, 1e-9));
    expect(ratio(3000), 1, reason: '最后一段走完就是整行');
    expect(ratio(9000), 1, reason: '超出也不该溢出');
  });

  test('字宽不等时按实际宽度计', () {
    const List<int> times = <int>[0, 1000];
    const List<double> weights = <double>[10, 30];
    expect(
      karaokeFillRatio(
        times: times,
        weights: weights,
        lineEndMs: 2000,
        positionMs: 1000,
      ),
      closeTo(0.25, 1e-9),
      reason: '第一段只占 10/40',
    );
  });

  test('时间轴缺失或宽度全 0 时给满（退化成整行亮）', () {
    expect(
      karaokeFillRatio(
        times: const <int>[],
        weights: const <double>[],
        lineEndMs: 1000,
        positionMs: 200,
      ),
      1,
    );
    expect(
      karaokeFillRatio(
        times: const <int>[0, 500],
        weights: const <double>[0, 0],
        lineEndMs: 1000,
        positionMs: 200,
      ),
      1,
    );
  });

  test('行索引随位置推进，第一行之前是 -1', () {
    final TrackLyrics lyrics = _lyrics(<int>[1500, 3000]);
    expect(desktopLineIndexAt(lyrics, 0), -1);
    expect(desktopLineIndexAt(lyrics, 1499), -1);
    expect(desktopLineIndexAt(lyrics, 1500), 0);
    expect(desktopLineIndexAt(lyrics, 3600), 1);
  });

  test('没有时间轴时两个函数都安全返回', () {
    const TrackLyrics empty = TrackLyrics(
      lines: <LyricLine>[],
      plain: '纯文本歌词',
      source: 'embedded',
    );
    expect(desktopLineAt(empty, 500), isNull);
    expect(nextDesktopLineStart(empty, 500), isNull);
    expect(
      desktopSecondLineAt(empty, 500, showTranslation: true),
      '',
      reason: '没有歌词时第二行就是空的，窗口那边不画',
    );
  });

  group('双行第二行', () {
    final TrackLyrics lyrics = _lyricsWithTranslations(
      <int>[0, 1000, 2500],
      <String>['第一句译文', '', '第三句译文\n罗马音'],
    );

    test('没开译文时第二行是下一句', () {
      expect(
        desktopSecondLineAt(lyrics, 0, showTranslation: false),
        'line 1000',
      );
      expect(
        desktopSecondLineAt(lyrics, 1200, showTranslation: false),
        'line 2500',
      );
    });

    test('开了译文且有译文时第二行是译文', () {
      expect(desktopSecondLineAt(lyrics, 0, showTranslation: true), '第一句译文');
      expect(desktopSecondLineAt(lyrics, 3600, showTranslation: true), '第三句译文');
    });

    test('本句没有译文时退回下一句', () {
      expect(
        desktopSecondLineAt(lyrics, 1200, showTranslation: true),
        'line 2500',
        reason: '这一句没有译文，第二行不能空着',
      );
    });

    test('第一句之前第二行就是第一句', () {
      final TrackLyrics later = _lyricsWithTranslations(
        <int>[2000, 4000],
        <String>['译文一', '译文二'],
      );
      expect(
        desktopSecondLineAt(later, 0, showTranslation: false),
        'line 2000',
      );
      expect(
        desktopSecondLineAt(later, 0, showTranslation: true),
        'line 2000',
        reason: '还没到第一句，没有「本句译文」可显示',
      );
    });

    test('最后一句之后没有下一句', () {
      expect(desktopSecondLineAt(lyrics, 9000, showTranslation: false), '');
      expect(
        desktopSecondLineAt(lyrics, 9000, showTranslation: true),
        '第三句译文',
        reason: '人还停在最后一句上（歌词没掐点结束），译文照旧显示',
      );
    });

    test('多段译文只取第一段非空的', () {
      const LyricLine line = LyricLine(
        timeMs: 0,
        endMs: 1000,
        text: 'text',
        words: <LyricWord>[],
        translation: '\n  罗马音  \n译文',
      );
      expect(desktopTranslationOf(line), '罗马音');
    });
  });
}
