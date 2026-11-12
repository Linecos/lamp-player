import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_player/src/features/library/library_sort.dart';
import 'package:lamp_player/src/rust/api/model.dart';

import '../../support/fake_library.dart';

void main() {
  group('标签兜底', () {
    test('空艺术家与空专辑使用统一文案', () {
      final Track track = sampleTrack(title: '无标签', artist: '  ', album: null);
      expect(trackArtist(track), unknownArtist);
      expect(trackAlbum(track), unknownAlbum);
    });

    test('有标签时去掉首尾空格', () {
      final Track track = sampleTrack(
        title: '夜航',
        artist: ' 林间电台 ',
        album: ' 夜航 ',
      );
      expect(trackArtist(track), '林间电台');
      expect(trackAlbum(track), '夜航');
    });
  });

  group('排序', () {
    test('默认就是标题升序', () {
      final List<Track> tracks = <Track>[
        sampleTrack(title: '乙', artist: 'B', addedAt: 100),
        sampleTrack(title: '甲', artist: 'A', addedAt: 300),
      ];

      expect(LibrarySort.defaultSort, LibrarySort.title);
      expect(LibrarySort.defaultSort.defaultAscending, isTrue);
      expect(
        sortTracks(tracks, LibrarySort.defaultSort).map((Track t) => t.title),
        <String>['乙', '甲'],
      );
    });

    test('按标题排序不区分大小写，且不改动入参', () {
      final List<Track> tracks = <Track>[
        sampleTrack(title: 'beta'),
        sampleTrack(title: 'Alpha'),
        sampleTrack(title: 'gamma'),
      ];

      final List<Track> sorted = sortTracks(tracks, LibrarySort.title);

      expect(sorted.map((Track track) => track.title), <String>[
        'Alpha',
        'beta',
        'gamma',
      ]);
      expect(tracks.first.title, 'beta', reason: 'sortTracks 不应原地排序');
    });

    test('按艺术家排序时，同一艺术家内按专辑、曲目号', () {
      final List<Track> tracks = <Track>[
        sampleTrack(title: '甲二', artist: 'A', album: 'Z', trackNum: 2),
        sampleTrack(title: '乙一', artist: 'B', album: 'A', trackNum: 1),
        sampleTrack(title: '甲一', artist: 'A', album: 'Z', trackNum: 1),
      ];

      final List<Track> sorted = sortTracks(tracks, LibrarySort.artist);

      expect(sorted.map((Track track) => track.title), <String>[
        '甲一',
        '甲二',
        '乙一',
      ]);
    });

    test('「最近添加」作为显式选项，与默认顺序结果一致', () {
      final List<Track> tracks = <Track>[
        sampleTrack(title: '旧', addedAt: 100),
        sampleTrack(title: '新', addedAt: 300),
        sampleTrack(title: '中', addedAt: 200),
      ];

      final List<String> byDefault = sortTracks(
        tracks,
        LibrarySort.added,
      ).map((Track track) => track.title).toList();
      // 切到「最近添加」时方向默认是降序（新的在前）
      final List<String> reversed = sortTracks(
        tracks,
        LibrarySort.added,
        ascending: true,
      ).map((Track track) => track.title).toList();

      expect(LibrarySort.added.defaultAscending, isFalse);
      expect(byDefault, <String>['新', '中', '旧']);
      expect(reversed, <String>['旧', '中', '新']);
    });

    test('同一时刻添加的曲目按标题兜底，顺序稳定', () {
      final List<Track> tracks = <Track>[
        sampleTrack(title: 'b', addedAt: 100),
        sampleTrack(title: 'a', addedAt: 100),
      ];

      expect(
        sortTracks(tracks, LibrarySort.added).map((Track t) => t.title),
        <String>['a', 'b'],
      );
    });

    test('按时长：默认升序，切方向就倒过来', () {
      final List<Track> tracks = <Track>[
        sampleTrack(title: '短', durationSecs: 60),
        sampleTrack(title: '长', durationSecs: 300),
        sampleTrack(title: '中', durationSecs: 120),
      ];

      expect(
        sortTracks(
          tracks,
          LibrarySort.duration,
        ).map((Track track) => track.title),
        <String>['短', '中', '长'],
      );
      expect(
        sortTracks(
          tracks,
          LibrarySort.duration,
          ascending: false,
        ).map((Track track) => track.title),
        <String>['长', '中', '短'],
      );
    });
  });

  group('多艺术家', () {
    test('按 / 拆开，顺序保留、首尾空格去掉、重复的去掉', () {
      final Track track = sampleTrack(
        title: 'Love Me Not',
        artist: ' Bao The Whale / Overspace / Bao The Whale ',
      );

      expect(trackArtist(track), 'Bao The Whale / Overspace / Bao The Whale');
      expect(splitTrackArtists(track), <String>['Bao The Whale', 'Overspace']);
    });

    test('没有分隔符或只有一段时原样返回', () {
      expect(
        splitTrackArtists(sampleTrack(title: 'x', artist: '林间电台')),
        <String>['林间电台'],
      );
      expect(
        splitTrackArtists(sampleTrack(title: 'x', artist: 'A / ')),
        <String>['A'],
      );
      expect(splitTrackArtists(sampleTrack(title: 'x', artist: '  ')), <String>[
        unknownArtist,
      ]);
    });

    test('AC/DC 这类缩写名不拆', () {
      expect(
        splitTrackArtists(sampleTrack(title: 'x', artist: 'AC/DC')),
        <String>['AC/DC'],
      );
      expect(
        splitTrackArtists(sampleTrack(title: 'x', artist: '王菲/那英')),
        <String>['王菲', '那英'],
        reason: '中文两字名不该被缩写规则挡住',
      );
    });

    test('多艺术家曲目同时归到两位艺术家下', () {
      final List<Track> tracks = <Track>[
        sampleTrack(title: 'Love Me Not', artist: 'Bao The Whale/Overspace'),
        sampleTrack(title: '独唱', artist: 'Overspace'),
      ];

      final List<ArtistGroup> groups = groupTracksByArtist(tracks);

      expect(groups.map((ArtistGroup g) => g.name), <String>[
        'Bao The Whale',
        'Overspace',
      ]);
      expect(groups.first.trackCount, 1);
      expect(groups.last.trackCount, 2, reason: 'Overspace 既有合唱也有独唱');
      expect(
        groups.any((ArtistGroup g) => g.name.contains('/')),
        isFalse,
        reason: '不该再留下「A/B」这种合体艺术家',
      );
    });
  });

  group('聚合', () {
    test('按艺术家聚合，统计专辑数与曲目数', () {
      final List<Track> tracks = <Track>[
        sampleTrack(title: '夜航', artist: '林间电台', album: '夜航'),
        sampleTrack(title: '灯下', artist: '林间电台', album: '夜航'),
        sampleTrack(title: '潮汐', artist: '海岸线', album: '玻璃海'),
      ];

      final List<ArtistGroup> groups = groupTracksByArtist(tracks);

      expect(groups.length, 2);
      // 中文按码位排序：林(U+6797) 在 海(U+6D77) 之前
      expect(groups.first.name, '林间电台');
      expect(groups.first.albumCount, 1);
      expect(groups.first.trackCount, 2);
      expect(groups.last.name, '海岸线');
      expect(groups.last.trackCount, 1);
    });

    test('同名专辑属于不同艺术家时不合并', () {
      final List<Track> tracks = <Track>[
        sampleTrack(title: '一', artist: 'A', album: '同名'),
        sampleTrack(title: '二', artist: 'B', album: '同名'),
      ];

      final List<AlbumGroup> groups = groupTracksByAlbum(tracks);

      expect(groups.length, 2);
      expect(groups.map((AlbumGroup group) => group.artist).toSet(), <String>{
        'A',
        'B',
      });
    });

    test('专辑封面取组内第一张有效封面', () {
      final List<Track> tracks = <Track>[
        sampleTrack(title: '一', artist: 'A', album: '专辑', trackNum: 1),
        sampleTrack(
          title: '二',
          artist: 'A',
          album: '专辑',
          trackNum: 2,
          coverPath: '/covers/a.jpg',
        ),
        sampleTrack(
          title: '三',
          artist: 'A',
          album: '专辑',
          trackNum: 3,
          coverPath: '/covers/b.jpg',
        ),
      ];

      expect(groupTracksByAlbum(tracks).single.coverPath, '/covers/a.jpg');
    });

    test('专辑内没有封面时 coverPath 为空', () {
      final List<Track> tracks = <Track>[
        sampleTrack(title: '一', artist: 'A', album: '专辑', trackNum: 1),
        sampleTrack(title: '二', artist: 'A', album: '专辑'),
      ];

      expect(groupTracksByAlbum(tracks).single.coverPath, isNull);
    });

    test('艺术家头像取组内第一首有封面的曲目', () {
      final List<Track> tracks = <Track>[
        // 故意乱序给：组内会按「专辑 → 曲目号」重排
        sampleTrack(
          title: '第三首',
          artist: '林间电台',
          album: '夜航',
          trackNum: 3,
          coverPath: '/covers/c.jpg',
        ),
        sampleTrack(
          title: '第一首',
          artist: '林间电台',
          album: '夜航',
          trackNum: 1,
          coverPath: '/covers/a.jpg',
        ),
        sampleTrack(
          title: '第二首',
          artist: '林间电台',
          album: '夜航',
          trackNum: 2,
          coverPath: '/covers/b.jpg',
        ),
      ];

      final ArtistGroup group = groupTracksByArtist(tracks).single;

      expect(group.coverPath, '/covers/a.jpg');
    });

    test('艺术家跨专辑时取最早那张专辑的第一首', () {
      final List<Track> tracks = <Track>[
        // 后加入的专辑排在后面，但相册顺序是 A → B，所以取 A 的封面
        sampleTrack(
          title: 'B-1',
          artist: '林间电台',
          album: 'B 面',
          trackNum: 1,
          coverPath: '/covers/b-album.jpg',
        ),
        sampleTrack(
          title: 'A-1',
          artist: '林间电台',
          album: 'A 面',
          trackNum: 1,
          coverPath: '/covers/a-album.jpg',
        ),
      ];

      expect(
        groupTracksByArtist(tracks).single.coverPath,
        '/covers/a-album.jpg',
      );
    });

    test('第一首没有封面时继续往后找，全都没有才回退空值', () {
      final List<Track> tracks = <Track>[
        sampleTrack(title: '一', artist: '林间电台', trackNum: 1),
        sampleTrack(
          title: '二',
          artist: '林间电台',
          trackNum: 2,
          coverPath: '/covers/second.jpg',
        ),
      ];

      expect(
        groupTracksByArtist(tracks).single.coverPath,
        '/covers/second.jpg',
      );
      expect(
        groupTracksByArtist(<Track>[
          sampleTrack(title: '一', artist: '海岸线', trackNum: 1),
          sampleTrack(title: '二', artist: '海岸线', trackNum: 2),
        ]).single.coverPath,
        isNull,
      );
    });

    test('专辑内按曲目号排序并累计时长', () {
      final List<Track> tracks = <Track>[
        sampleTrack(
          title: '第二首',
          artist: 'A',
          album: '专辑',
          trackNum: 2,
          durationSecs: 200,
        ),
        sampleTrack(
          title: '第一首',
          artist: 'A',
          album: '专辑',
          trackNum: 1,
          durationSecs: 100,
        ),
      ];

      final AlbumGroup group = groupTracksByAlbum(tracks).single;

      expect(group.tracks.map((Track track) => track.title), <String>[
        '第一首',
        '第二首',
      ]);
      expect(group.durationSecs, 300);
    });
  });
}
