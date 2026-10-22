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
    test('默认顺序保持调用方给出的顺序', () {
      final List<Track> tracks = <Track>[
        sampleTrack(title: '乙', artist: 'B'),
        sampleTrack(title: '甲', artist: 'A'),
      ];

      expect(
        sortTracks(tracks, LibrarySort.library).map((Track t) => t.title),
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

    test('按最近添加倒序', () {
      final List<Track> tracks = <Track>[
        sampleTrack(title: '旧', addedAt: 100),
        sampleTrack(title: '新', addedAt: 300),
        sampleTrack(title: '中', addedAt: 200),
      ];

      expect(
        sortTracks(tracks, LibrarySort.added).map((Track track) => track.title),
        <String>['新', '中', '旧'],
      );
    });

    test('按时长倒序', () {
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
        <String>['长', '中', '短'],
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
