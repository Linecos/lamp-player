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

  test('洗牌袋：一轮之内每首正好放一次，没有最后一首', () {
    final List<Track> tracks = <Track>[
      for (int i = 0; i < 8; i += 1) sampleTrack(title: 'T$i'),
    ];
    final PlaybackQueue queue = PlaybackQueue(
      tracks: tracks,
      // 不传 repeat，默认 off —— 随机模式不该受它影响
      shuffle: true,
      random: Random(7),
    );

    // 从当前曲目之后开始连放 8 首：整轮跑完，每个下标恰好出现一次
    final List<int> played = <int>[];
    for (int i = 0; i < tracks.length; i += 1) {
      final int? next = queue.advance();
      expect(next, isNotNull, reason: '第 ${i + 1} 次切歌不该遇到"最后一首"');
      played.add(next!);
    }
    expect(played.toSet(), <int>{
      0,
      1,
      2,
      3,
      4,
      5,
      6,
      7,
    }, reason: '一轮之内既不放重、也不漏放（这正是「某首反复来」的根因）');
    expect(played.toSet().length, played.length, reason: '一轮之内不重复');
    expect(queue.hasNext, isTrue, reason: '袋子空了会自动重洗，永远有下一首');
  });

  test('洗牌袋：轮末接到轮首时也不会连放同一首', () {
    final PlaybackQueue queue = PlaybackQueue(
      tracks: _tracks(),
      shuffle: true,
      random: Random(3),
    );

    int previous = queue.index;
    for (int i = 0; i < 40; i += 1) {
      final int? next = queue.advance();
      expect(next, isNotNull);
      expect(next, isNot(previous), reason: '第 ${i + 1} 次切歌连放了同一首');
      previous = next!;
    }
  });

  test('重排队列后洗牌袋跟着平移，不会放重也不会漏放', () {
    final List<Track> tracks = <Track>[
      for (int i = 0; i < 8; i += 1) sampleTrack(title: 'M$i'),
    ];
    final PlaybackQueue queue = PlaybackQueue(
      tracks: tracks,
      shuffle: true,
      random: Random(11),
    );

    final Set<String> played = <String>{queue.current!.path};
    for (int i = 0; i < 3; i += 1) {
      played.add(queue.tracks[queue.advance()!].path);
    }

    // 拖动重排：袋里的下标必须跟着一起 remap，否则会指向别的歌
    queue.move(0, 7);

    for (int i = 0; i < 5; i += 1) {
      played.add(queue.tracks[queue.advance()!].path);
    }
    expect(played.length, 8, reason: '一整轮仍要覆盖所有曲目，重排不能让某首放两遍');
  });

  test('删曲之后洗牌袋不会指向已经删掉的歌', () {
    final List<Track> tracks = <Track>[
      for (int i = 0; i < 6; i += 1) sampleTrack(title: 'R$i'),
    ];
    final PlaybackQueue queue = PlaybackQueue(
      tracks: tracks,
      shuffle: true,
      random: Random(13),
    );

    expect(queue.removeAt(5), isFalse, reason: '删的是队尾那首，不是当前曲目');
    // 不收拾袋子的话，袋里那个 5 就成了越界下标：切歌会拿不到曲目
    for (int i = 0; i < 10; i += 1) {
      final int? next = queue.advance();
      expect(next, isNotNull);
      expect(next! < queue.length, isTrue, reason: '下标必须落在剩余队列里');
    }
  });

  test('随机播放不改变队列显示顺序，从列表上看不出下一首', () {
    final PlaybackQueue queue = PlaybackQueue(
      tracks: _tracks(),
      shuffle: true,
      random: Random(5),
    );
    final List<String> before = _titles(queue.tracks);

    for (int i = 0; i < 12; i += 1) {
      queue.advance();
    }

    expect(
      _titles(queue.tracks),
      before,
      reason: '随机只体现在当前下标上；列表一旦被重排，用户就能"看出来"下一首了',
    );
  });

  test('随机抽到的下一首是稳定的：连问几次结果不变，切过去才重抽', () {
    final PlaybackQueue queue = PlaybackQueue(
      tracks: _tracks(),
      shuffle: true,
      random: Random(7),
    );

    final int? picked = queue.peekNext();
    expect(picked, isNotNull);
    expect(queue.peekNext(), picked);
    expect(queue.hasNext, isTrue, reason: 'hasNext 内部也会问一次，但不该改结果');
    expect(queue.advance(), picked);
  });

  test('随机模式下只有一首也会重播', () {
    final PlaybackQueue queue = PlaybackQueue(
      tracks: <Track>[sampleTrack(title: 'A')],
      shuffle: true,
      random: Random(1),
    );

    expect(queue.peekNext(), 0);
    expect(queue.advance(auto: true), 0);
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

  test('随机模式下追加曲目不会改变已经抽好的下一首', () {
    final PlaybackQueue queue = PlaybackQueue(
      tracks: _tracks(),
      shuffle: true,
      random: Random(7),
    );
    final int? before = queue.peekNext();

    expect(queue.append(sampleTrack(title: 'D')), isTrue);
    expect(queue.peekNext(), before, reason: '追加不应换掉已经抽好的下一首');
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

  test('拖动重排：正在播放的曲目跟着自己的下标走', () {
    final PlaybackQueue queue = PlaybackQueue(tracks: _tracks());
    queue.jumpTo(1);
    final String playing = queue.current!.title;

    // 把第 1 首挪到队首：当前曲目原来是下标 1，现在应该变成 0
    queue.move(1, 0);

    expect(_titles(queue.tracks), <String>[playing, 'A', 'C']);
    expect(queue.current?.title, playing, reason: '不该因为前面的行被挪动而换歌');
    expect(queue.index, 0);
  });

  test('拖动重排：往右拖时中间曲目整体左移', () {
    final PlaybackQueue queue = PlaybackQueue(tracks: _tracks());
    queue.jumpTo(1);

    queue.move(0, 2);

    expect(_titles(queue.tracks), <String>['B', 'C', 'A']);
    expect(queue.index, 0, reason: '被移走的那首原本在当前曲目之前，当前下标要减一');
    expect(queue.current?.title, 'B');
  });

  test('拖动重排：越界参数被夹住，空队列不炸', () {
    final PlaybackQueue queue = PlaybackQueue(tracks: _tracks());
    queue.move(0, 99);
    expect(_titles(queue.tracks), <String>['B', 'C', 'A']);
    queue.move(9, 0);
    expect(queue.length, 3, reason: '越界的 from 直接忽略');

    final PlaybackQueue empty = PlaybackQueue();
    empty.move(0, 1);
    expect(empty.isEmpty, isTrue);
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

  test('修订号只在队列结构变化时前进，切歌与换模式不动它', () {
    final PlaybackQueue queue = PlaybackQueue(tracks: _tracks());
    final int start = queue.structureRevision;

    queue.advance();
    queue.retreat();
    queue.jumpTo(2);
    queue.setRepeat(LoopMode.all);
    queue.setShuffle(true);
    queue.refreshTracks(_tracks());
    expect(queue.structureRevision, start, reason: '路径没变：会话只需要补写下标，不必重写整串路径');

    queue.move(0, 2);
    final int afterMove = queue.structureRevision;
    expect(afterMove, greaterThan(start));

    queue.append(sampleTrack(title: 'D'));
    final int afterAppend = queue.structureRevision;
    expect(afterAppend, greaterThan(afterMove));

    queue.insertNext(sampleTrack(title: 'E'));
    final int afterInsert = queue.structureRevision;
    expect(afterInsert, greaterThan(afterAppend));

    queue.removeAt(0);
    final int afterRemove = queue.structureRevision;
    expect(afterRemove, greaterThan(afterInsert));

    queue.reset(<Track>[sampleTrack(title: 'X')]);
    expect(queue.structureRevision, greaterThan(afterRemove));

    queue.clear();
    expect(queue.structureRevision, greaterThan(afterRemove + 1));
  });
}
