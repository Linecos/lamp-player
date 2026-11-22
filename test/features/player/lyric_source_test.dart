import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_player/src/features/player/lyric_source.dart';

void main() {
  test('默认顺序是旁载优先', () {
    expect(lyricSourceOrderDefault, <LyricSource>[
      LyricSource.sidecar,
      LyricSource.embedded,
    ]);
    expect(embeddedFirstIn(lyricSourceOrderDefault), isFalse);
  });

  test('还原顺序：认识的留着，缺的补到末尾，垃圾丢掉', () {
    expect(lyricSourceOrderFromIds(null), lyricSourceOrderDefault);
    expect(lyricSourceOrderFromIds(<String>[]), lyricSourceOrderDefault);
    expect(
      lyricSourceOrderFromIds(<String>['embedded', 'sidecar']),
      <LyricSource>[LyricSource.embedded, LyricSource.sidecar],
    );
    expect(
      lyricSourceOrderFromIds(<String>['cloud', 'embedded']),
      <LyricSource>[LyricSource.embedded, LyricSource.sidecar],
      reason: '缺的旁载补在末尾',
    );
    expect(
      lyricSourceOrderFromIds(<String>['embedded', 'embedded']),
      <LyricSource>[LyricSource.embedded, LyricSource.sidecar],
      reason: '重复的只留第一次',
    );
  });

  test('id 列表与 embeddedFirst 一致', () {
    expect(lyricSourceOrderIds(lyricSourceOrderDefault), <String>[
      'sidecar',
      'embedded',
    ]);
    expect(
      embeddedFirstIn(<LyricSource>[LyricSource.embedded, LyricSource.sidecar]),
      isTrue,
    );
    expect(embeddedFirstIn(const <LyricSource>[]), isFalse);
  });
}
