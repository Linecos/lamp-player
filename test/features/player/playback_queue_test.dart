import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_player/src/features/player/playback_queue.dart';
import 'package:lamp_player/src/rust/api/model.dart';

import '../../support/fake_library.dart';

List<Track> _tracks() => <Track>[
  sampleTrack(title: 'A'),
  sampleTrack(title: 'B'),
  sampleTrack(title: 'C'),
];

List<String> _titles(List<Track> tracks) =>
    tracks.map((Track track) => track.title).toList();

void main() {
  test('顺序播放：下一首 / 上一首按历史回退', () {
    final PlaybackQueue queue = PlaybackQueue(tracks: _tracks());

    expect(queue.current?.title, 'A');
    expect(queue.advance(), 1);
    expect(queue.advance(), 2);
    expect(queue.current?.title, 'C');
    expect(queue.advance(), isNull, reason: '不循环时到队尾就结束');

    expect(queue.retreat(), 1);
    expect(queue.current?.title, 'B');
    expect(queue.retreat(), 0);
    expect(queue.current?.title, 'A');
    expect(queue.retreat(), isNull, reason: '已到队首且不循环');
  });

  test('列表循环：队尾回到队首，队首上一首回到队尾', () {
    final PlaybackQueue queue = PlaybackQueue(
      tracks: _tracks(),
      repeat: LoopMode.all,
    );

    expect(queue.advance(), 1);
    expect(queue.advance(), 2);
    expect(queue.advance(), 0);
    expect(queue.current?.title, 'A');
    expect(queue.retreat(), 2);
  });

  test('单曲循环只对自然播完生效，手动下一首仍切歌', () {
    final PlaybackQueue queue = PlaybackQueue(
      tracks: _tracks(),
      repeat: LoopMode.one,
    );

    expect(queue.advance(auto: true), 0, reason: '自然播完重播本曲');
    expect(queue.current?.title, 'A');

    expect(queue.advance(), 1, reason: '手动下一首应切歌');
    expect(queue.current?.title, 'B');
  });

  test('随机播放一轮内不重复，循环模式会重洗', () {
    final PlaybackQueue queue = PlaybackQueue(
      tracks: _tracks(),
      repeat: LoopMode.all,
      shuffle: true,
      random: Random(7),
    );

    final Set<String> visited = <String>{};
    for (int i = 0; i < 3; i += 1) {
      visited.add(queue.current!.title);
      queue.advance();
    }
    expect(visited.length, 3, reason: '一轮内每首只出现一次');
    expect(queue.current?.title, isNotNull);
  });

  test('插入下一首与追加都会去重并移动已有曲目', () {
    final PlaybackQueue queue = PlaybackQueue(tracks: _tracks());
    final Track c = queue.tracks[2];

    expect(queue.insertNext(c), isTrue);
    expect(_titles(queue.tracks), <String>['A', 'C', 'B']);
    expect(queue.current?.title, 'A');

    expect(queue.append(c), isFalse, reason: '队列里已有，不重复追加');
    expect(queue.append(sampleTrack(title: 'D')), isTrue);
    expect(queue.tracks.last.title, 'D');
  });

  test('reset 清空历史并重新开始', () {
    final PlaybackQueue queue = PlaybackQueue(tracks: _tracks());
    queue.advance();
    queue.advance();

    queue.reset(<Track>[sampleTrack(title: 'X')]);
    expect(queue.length, 1);
    expect(queue.current?.title, 'X');
    expect(queue.retreat(), isNull);
  });
}
