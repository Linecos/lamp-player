import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_player/src/features/library/playlist_io.dart';
import 'package:lamp_player/src/rust/api/model.dart';

Track _track(
  String path, {
  String title = '标题',
  String? artist = '艺术家',
  double duration = 123,
}) => Track(
  path: path,
  title: title,
  artist: artist,
  album: '专辑',
  durationSecs: duration,
  trackNum: 1,
  addedAt: 0,
  coverPath: null,
);

void main() {
  group('buildM3U8', () {
    test('生成文件头、歌单名与逐条曲目', () {
      final String content = buildM3U8(
        playlistName: '深夜通勤',
        tracks: <Track>[
          _track(
            r'E:\Music\a.flac',
            title: '夜航',
            artist: '某人',
            duration: 200.4,
          ),
          _track(r'E:\Music\b.mp3', title: '无艺术家歌', artist: null),
        ],
      );

      final List<String> lines = content.split('\n');
      expect(lines[0], '#EXTM3U');
      expect(lines[1], '#PLAYLIST:深夜通勤');
      expect(lines[2], '#EXTINF:200,某人 - 夜航');
      expect(lines[3], r'E:\Music\a.flac');
      expect(lines[4], '#EXTINF:123, - 无艺术家歌');
      expect(lines[5], r'E:\Music\b.mp3');
    });

    test('空歌单名时省略 #PLAYLIST 行', () {
      final String content = buildM3U8(
        playlistName: '',
        tracks: const <Track>[],
      );
      expect(content, '#EXTM3U\n');
    });
  });

  group('parseM3U', () {
    test('解析标准结构（EXTINF 元信息 + 路径）', () {
      const String content = '''
#EXTM3U
#PLAYLIST:我的歌单
#EXTINF:200,某人 - 夜航
E:\\Music\\a.flac
#EXTINF:95,别人 - 另一首
E:\\Music\\b.mp3
''';
      final ParsedM3U parsed = parseM3U(content);

      expect(parsed.playlistName, '我的歌单');
      expect(parsed.entries, hasLength(2));
      expect(parsed.entries[0].path, r'E:\Music\a.flac');
      expect(parsed.entries[0].durationSecs, 200);
      expect(parsed.entries[0].artist, '某人');
      expect(parsed.entries[0].title, '夜航');
      expect(parsed.entries[1].path, r'E:\Music\b.mp3');
      expect(parsed.entries[1].durationSecs, 95);
    });

    test('兼容 BOM、CRLF、无 EXTINF 的裸路径与未知注释行', () {
      const String content =
          '\ufeff#EXTM3U\r\n'
          '#EXTM3U\r\n'
          '#EXT-X-VERSION:3\r\n'
          '\r\n'
          'E:\\Music\\x.flac\r\n'
          '#EXTINF:10,\r\n'
          'E:\\Music\\y.flac\r\n';
      final ParsedM3U parsed = parseM3U(content);

      expect(parsed.playlistName, isNull);
      expect(parsed.entries, hasLength(2));
      expect(parsed.entries[0].path, r'E:\Music\x.flac');
      expect(parsed.entries[0].durationSecs, isNull);
      expect(parsed.entries[1].durationSecs, 10);
    });

    test('EXTINF 无艺术家（不含 " - "）时整段作为标题', () {
      const String content = '#EXTINF:30,只有标题\nE:\\a.flac\n';
      final ParsedM3U parsed = parseM3U(content);

      expect(parsed.entries.single.artist, isNull);
      expect(parsed.entries.single.title, '只有标题');
    });

    test('导出再导入能还原曲目与歌单名', () {
      final List<Track> tracks = <Track>[
        _track(r'E:\M\one.flac', title: '一'),
        _track(r'E:\M\two.flac', title: '二'),
      ];
      final ParsedM3U parsed = parseM3U(
        buildM3U8(playlistName: '往返', tracks: tracks),
      );

      expect(parsed.playlistName, '往返');
      expect(
        parsed.entries.map((M3UEntry e) => e.path),
        tracks.map((Track t) => t.path),
      );
    });
  });

  group('matchImportedEntries', () {
    final List<Track> library = <Track>[
      _track(r'E:\Music\a.flac', title: 'A'),
      _track(r'E:\Music\Sub\b.flac', title: 'B'),
      _track(r'E:\Other\duplicate.flac', title: 'Dup1'),
      _track(r'E:\Elsewhere\duplicate.flac', title: 'Dup2'),
    ];

    test('路径匹配不受大小写与分隔符影响', () {
      final List<Track> matched = matchImportedEntries(<M3UEntry>[
        const M3UEntry(path: r'e:/MUSIC/A.FLAC'),
        const M3UEntry(path: r'E:\music\sub\B.flac'),
      ], library);

      expect(matched.map((Track t) => t.title).toList(), <String>['A', 'B']);
    });

    test('路径对不上时按唯一文件名兜底', () {
      final List<Track> matched = matchImportedEntries(<M3UEntry>[
        const M3UEntry(path: r'F:\Somewhere\Else\a.flac'),
      ], library);

      expect(matched.single.title, 'A');
    });

    test('同名文件有歧义时不兜底', () {
      final List<Track> matched = matchImportedEntries(<M3UEntry>[
        const M3UEntry(path: r'X:\nowhere\duplicate.flac'),
      ], library);

      expect(matched, isEmpty);
    });

    test('重复条目去重，保持导入顺序', () {
      final List<Track> matched = matchImportedEntries(<M3UEntry>[
        const M3UEntry(path: r'E:\Music\b.flac'),
        const M3UEntry(path: r'E:\Music\a.flac'),
        const M3UEntry(path: r'E:\Music\Sub\b.flac'),
      ], library);

      expect(matched.map((Track t) => t.title).toList(), <String>['B', 'A']);
    });

    test('importStats 报告匹配数与总数', () {
      final List<M3UEntry> entries = <M3UEntry>[
        const M3UEntry(path: r'E:\Music\a.flac'),
        const M3UEntry(path: r'M:\missing.flac'),
      ];
      final List<Track> matched = matchImportedEntries(entries, library);

      final ({int matched, int total}) stats = importStats(entries, matched);
      expect(stats.matched, 1);
      expect(stats.total, 2);
    });
  });
}
