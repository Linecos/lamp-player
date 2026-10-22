import 'package:lamp_player/src/features/library/library_repository.dart';
import 'package:lamp_player/src/features/player/playback_service.dart';
import 'package:lamp_player/src/rust/api/model.dart';
import 'package:lamp_player/src/rust/api/player.dart' as rust;

/// 构造测试曲目；字段默认值与真实扫描结果保持一致（path 唯一）。
Track sampleTrack({
  required String title,
  String? artist = '林间电台',
  String? album = '夜航',
  double durationSecs = 180,
  int? trackNum,
  int addedAt = 0,
  String? path,
}) {
  return Track(
    path: path ?? '/music/$title.mp3',
    title: title,
    artist: artist,
    album: album,
    durationSecs: durationSecs,
    trackNum: trackNum,
    addedAt: addedAt,
  );
}

/// 不依赖 Rust 的曲库数据源。
class FakeLibraryRepository implements LibraryRepository {
  FakeLibraryRepository({List<Track>? tracks, this.loadError, this.searchError})
    : tracks = tracks ?? <Track>[];

  List<Track> tracks;
  Object? loadError;
  Object? searchError;

  int loadCalls = 0;
  int searchCalls = 0;
  String lastQuery = '';

  @override
  Future<List<Track>> loadTracks() async {
    loadCalls += 1;
    if (loadError != null) {
      throw loadError!;
    }
    return List<Track>.of(tracks);
  }

  @override
  Future<List<Track>> searchTracks(String query, {int limit = 500}) async {
    searchCalls += 1;
    lastQuery = query;
    if (searchError != null) {
      throw searchError!;
    }
    final String needle = query.toLowerCase();
    return tracks
        .where((Track track) {
          final String haystack =
              '${track.title} ${track.artist} ${track.album}'.toLowerCase();
          return haystack.contains(needle);
        })
        .take(limit)
        .toList();
  }
}

/// 不依赖 BASS 的播放实现。
class FakePlaybackService implements PlaybackService {
  FakePlaybackService({
    this.isAvailable = false,
    this.positionSecs = 0,
    this.durationSecs = 0,
  });

  @override
  bool isAvailable;

  double positionSecs;
  double durationSecs;

  rust.PlaybackState current = rust.PlaybackState.stopped;
  final List<String> playedPaths = <String>[];
  int pauseCalls = 0;
  int resumeCalls = 0;
  int stopCalls = 0;

  @override
  rust.PlaybackState get state => current;

  @override
  Future<void> play(String path) async {
    playedPaths.add(path);
    current = rust.PlaybackState.playing;
  }

  @override
  Future<void> pause() async {
    pauseCalls += 1;
    current = rust.PlaybackState.paused;
  }

  @override
  Future<void> resume() async {
    resumeCalls += 1;
    current = rust.PlaybackState.playing;
  }

  @override
  Future<void> stop() async {
    stopCalls += 1;
    current = rust.PlaybackState.stopped;
  }

  @override
  Future<double> position() async => positionSecs;

  @override
  Future<double> duration() async => durationSecs;
}
