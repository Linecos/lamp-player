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

  test('随机模式下「下一首播放」仍然先播指定曲目', () {
    final PlaybackQueue queue = PlaybackQueue(
      tracks: _tracks(),
      shuffle: true,
      random: Random(7),
    );
    final Track target = _tracks()[2];

    expect(queue.insertNext(target), isTrue);
    final int expected = queue.tracks.indexWhere(
      (Track track) => track.path == target.path,
    );
    expect(queue.peekNext(), expected, reason: '随机顺序里也应排在当前曲之后');
    expect(queue.advance(), expected);
    expect(queue.current?.title, 'C');
  });

  test('随机模式下追加曲目不会打乱这一轮的顺序', () {
    final PlaybackQueue queue = PlaybackQueue(
      tracks: _tracks(),
      shuffle: true,
      random: Random(7),
    );
    final int? before = queue.peekNext();

    expect(queue.append(sampleTrack(title: 'D')), isTrue);
    expect(queue.peekNext(), before, reason: '追加不应重洗待播顺序');
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

  test('刷新曲目对象后保留顺序、当前下标与上一首历史', () {
    final PlaybackQueue queue = PlaybackQueue(tracks: _tracks());
    queue.advance(); // A -> B
    final String currentPath = queue.current!.path;

    queue.refreshTracks(<Track>[
      sampleTrack(title: 'A', coverPath: '/covers/a.jpg'),
      sampleTrack(title: 'B', coverPath: '/covers/b.jpg'),
      sampleTrack(title: 'C', coverPath: '/covers/c.jpg'),
    ]);

    expect(queue.index, 1);
    expect(queue.current?.path, currentPath);
    expect(queue.current?.coverPath, '/covers/b.jpg', reason: '播放条应拿到新封面');
    expect(_titles(queue.tracks), <String>['A', 'B', 'C']);
    expect(queue.retreat(), 0, reason: '上一首历史不应被刷新清掉');
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

  test('把刚播过的曲目设为下一首后，上一首不会重播当前曲', () {
    final PlaybackQueue queue = PlaybackQueue(tracks: _tracks());
    queue.advance(); // A -> B
    queue.advance(); // B -> C

    queue.insertNext(_tracks()[1]); // 把刚播过的 B 提到当前曲之后
    expect(_titles(queue.tracks), <String>['A', 'C', 'B']);
    expect(queue.current?.title, 'C');

    queue.retreat();
    expect(queue.current?.title, 'A', reason: '历史里被移走的下标应被删除，而不是左移');
  });

  test('移除当前曲目后，后一首顶上并成为当前曲', () {
    final PlaybackQueue queue = PlaybackQueue(tracks: _tracks());
    queue.advance(); // A -> B

    expect(queue.removeAt(1), isTrue, reason: '删的是当前曲');
    expect(_titles(queue.tracks), <String>['A', 'C']);
    expect(queue.current?.title, 'C');
  });

  test('移除当前曲目前面的曲目时下标左移', () {
    final PlaybackQueue queue = PlaybackQueue(tracks: _tracks());
    queue.advance(); // A -> B（下标 1）

    expect(queue.removeAt(0), isFalse);
    expect(queue.index, 0);
    expect(queue.current?.title, 'B');
  });

  test('移除最后一首当前曲目后回退到新的队尾', () {
    final PlaybackQueue queue = PlaybackQueue(tracks: _tracks());
    queue.advance();
    queue.advance(); // 当前 C（下标 2）

    expect(queue.removeAt(2), isTrue);
    expect(queue.current?.title, 'B');
  });

  test('移除曲目后上一首历史仍指向正确的曲目', () {
    final PlaybackQueue queue = PlaybackQueue(
      tracks: <Track>[
        sampleTrack(title: 'A'),
        sampleTrack(title: 'B'),
        sampleTrack(title: 'C'),
      ],
    );
    queue.advance(); // A -> B
    queue.advance(); // B -> C

    // 删掉队首 A：历史里的 0 应被清掉、1 左移成 0
    queue.removeAt(0);
    expect(queue.current?.title, 'C');
    expect(queue.retreat(), 0);
    expect(queue.current?.title, 'B');
  });

  test('随机播放时移除其它曲目不会改变当前曲', () {
    final PlaybackQueue queue = PlaybackQueue(
      tracks: _tracks(),
      shuffle: true,
      random: Random(7),
    );
    final String current = queue.current!.title;

    expect(queue.removeAt(2), isFalse);
    expect(queue.current?.title, current);
    expect(queue.length, 2);
  });

  test('清空队列后回到空状态', () {
    final PlaybackQueue queue = PlaybackQueue(tracks: _tracks());
    queue.advance();

    queue.clear();

    expect(queue.isEmpty, isTrue);
    expect(queue.index, -1);
    expect(queue.current, isNull);
    expect(queue.advance(), isNull);
    expect(queue.retreat(), isNull);
  });
}
