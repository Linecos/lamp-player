import 'package:lamp_player/src/app/session_store.dart';
import 'package:lamp_player/src/features/library/library_repository.dart';
import 'package:lamp_player/src/features/player/playback_service.dart';
import 'package:lamp_player/src/features/settings/music_folder_store.dart';
import 'package:lamp_player/src/rust/api/model.dart';
import 'package:lamp_player/src/rust/api/player.dart' as rust;
import 'package:lamp_player/src/rust/api/scan.dart';

/// 构造测试曲目；字段默认值与真实扫描结果保持一致（path 唯一）。
Track sampleTrack({
  required String title,
  String? artist = '林间电台',
  String? album = '夜航',
  double durationSecs = 180,
  int? trackNum,
  int addedAt = 0,
  String? path,
  String? coverPath,
}) {
  return Track(
    path: path ?? '/music/$title.mp3',
    title: title,
    artist: artist,
    album: album,
    durationSecs: durationSecs,
    trackNum: trackNum,
    addedAt: addedAt,
    coverPath: coverPath,
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
  final List<String> scannedFolders = <String>[];

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

  @override
  Future<ScanReport> scanFolder(String folder) async {
    scannedFolders.add(folder);
    return const ScanReport(
      scanned: 0,
      unchanged: 0,
      upserted: 0,
      failed: 0,
      walkErrors: 0,
      pruned: 0,
      elapsedMs: 0,
    );
  }

  // --- 歌单 / 收藏 / 历史：内存实现，行为与 Rust 侧契约保持一致 ---

  final Map<int, _FakePlaylist> _playlists = <int, _FakePlaylist>{};
  final Set<String> _favorites = <String>{};
  final List<String> _history = <String>[];
  int _nextPlaylistId = 1;

  Track? _trackByPath(String path) {
    for (final Track track in tracks) {
      if (track.path == path) {
        return track;
      }
    }
    return null;
  }

  List<Track> _tracksByPaths(Iterable<String> paths) =>
      paths.map(_trackByPath).whereType<Track>().toList();

  _FakePlaylist _playlistById(int id) {
    final _FakePlaylist? playlist = _playlists[id];
    if (playlist == null) {
      throw StateError('歌单不存在: $id');
    }
    return playlist;
  }

  void _ensureNameAvailable(String name, {int? exceptId}) {
    if (name.isEmpty) {
      throw ArgumentError('歌单名不能为空');
    }
    final String lower = name.toLowerCase();
    final bool taken = _playlists.values.any(
      (_FakePlaylist p) => p.id != exceptId && p.name.toLowerCase() == lower,
    );
    if (taken) {
      throw StateError('已存在同名歌单: $name');
    }
  }

  @override
  Future<List<Playlist>> loadPlaylists() async {
    final List<Playlist> result = _playlists.values.map(_toPlaylist).toList();
    result.sort((Playlist a, Playlist b) => a.name.compareTo(b.name));
    return result;
  }

  @override
  Future<Playlist> createPlaylist(String name) async {
    final String trimmed = name.trim();
    _ensureNameAvailable(trimmed);
    final _FakePlaylist playlist = _FakePlaylist(_nextPlaylistId++, trimmed);
    _playlists[playlist.id] = playlist;
    return _toPlaylist(playlist);
  }

  @override
  Future<void> renamePlaylist(int id, String name) async {
    final _FakePlaylist playlist = _playlistById(id);
    final String trimmed = name.trim();
    _ensureNameAvailable(trimmed, exceptId: id);
    playlist
      ..name = trimmed
      ..updatedAt = _now();
  }

  @override
  Future<void> deletePlaylist(int id) async {
    _playlistById(id);
    _playlists.remove(id);
  }

  @override
  Future<List<Track>> loadPlaylistTracks(int id) async =>
      _tracksByPaths(_playlistById(id).paths);

  @override
  Future<bool> addTrackToPlaylist(int id, String path) async {
    final _FakePlaylist playlist = _playlistById(id);
    if (_trackByPath(path) == null) {
      throw StateError('曲目不在曲库: $path');
    }
    if (playlist.paths.contains(path)) {
      return false;
    }
    playlist
      ..paths.add(path)
      ..updatedAt = _now();
    return true;
  }

  @override
  Future<bool> removeTrackFromPlaylist(int id, String path) async {
    final _FakePlaylist playlist = _playlistById(id);
    if (!playlist.paths.remove(path)) {
      return false;
    }
    playlist.updatedAt = _now();
    return true;
  }

  @override
  Future<List<Track>> loadFavorites() async => _tracksByPaths(_favorites);

  @override
  Future<Set<String>> loadFavoritePaths() async => Set<String>.of(_favorites);

  @override
  Future<bool> isFavorite(String path) async => _favorites.contains(path);

  @override
  Future<void> setFavorite(String path, bool favorite) async {
    if (favorite) {
      if (_trackByPath(path) == null) {
        throw StateError('曲目不在曲库: $path');
      }
      _favorites.add(path);
    } else {
      _favorites.remove(path);
    }
  }

  @override
  Future<void> recordPlay(String path) async {
    if (_trackByPath(path) == null) {
      throw StateError('曲目不在曲库: $path');
    }
    _history
      ..remove(path)
      ..insert(0, path);
  }

  @override
  Future<List<Track>> loadRecentTracks({int limit = 100}) async =>
      _tracksByPaths(_history.take(limit.clamp(1, 500)));

  @override
  Future<void> clearHistory() async => _history.clear();

  Playlist _toPlaylist(_FakePlaylist playlist) => Playlist(
    id: playlist.id,
    name: playlist.name,
    trackCount: playlist.paths.length,
    createdAt: playlist.createdAt,
    updatedAt: playlist.updatedAt,
  );
}

/// 内存版目录存储。
class FakeMusicFolderStore implements MusicFolderStore {
  FakeMusicFolderStore({List<String>? folders})
    : folders = List<String>.of(folders ?? const <String>[]);

  List<String> folders;
  int saveCalls = 0;

  @override
  Future<List<String>> load() async => List<String>.of(folders);

  @override
  Future<void> save(List<String> next) async {
    saveCalls += 1;
    folders = List<String>.of(next);
  }
}

/// 内存版会话存储：测试里避免依赖 shared_preferences 插件。
class FakeSessionStore implements SessionStore {
  FakeSessionStore({SessionSnapshot? snapshot})
    // 默认视为已补扫过，普通测试不会因为示例曲目没有封面而触发自动扫描；
    // 需要验证补扫的用例显式传 `coverBackfillAttempted: false`。
    : snapshot =
          snapshot ?? const SessionSnapshot(coverBackfillAttempted: true);

  SessionSnapshot snapshot;
  int saveCalls = 0;

  @override
  Future<SessionSnapshot> load() async => snapshot;

  @override
  Future<void> save(SessionSnapshot snapshot) async {
    saveCalls += 1;
    this.snapshot = snapshot;
  }
}

int _now() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

class _FakePlaylist {
  _FakePlaylist(this.id, this.name) : createdAt = _now(), updatedAt = _now();

  final int id;
  String name;
  int createdAt;
  int updatedAt;
  final List<String> paths = <String>[];
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

  /// 非空时 `position()` 抛出该错误，用于测试轮询容错
  Object? positionError;

  /// 非空时 `play()` 抛出该错误，用于测试播放失败后的降级
  Object? playError;

  /// 非空时 `seek()` 抛出该错误，用于测试恢复进度的失败路径
  Object? seekError;

  rust.PlaybackState current = rust.PlaybackState.stopped;
  final List<String> playedPaths = <String>[];
  final List<double> seekCalls = <double>[];
  final List<double> volumeCalls = <double>[];
  int pauseCalls = 0;
  int resumeCalls = 0;
  int stopCalls = 0;

  /// WASAPI 独占：`exclusive` 是实际状态，`exclusiveError` 用于模拟切换失败
  bool exclusive = false;
  Object? exclusiveError;
  int exclusiveCalls = 0;
  int outputInfoCalls = 0;
  String outputInfoText = '共享输出（测试）';

  @override
  rust.PlaybackState get state => current;

  @override
  Future<void> play(String path) async {
    final Object? error = playError;
    if (error != null) {
      throw error;
    }
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
  Future<double> position() async {
    final Object? error = positionError;
    if (error != null) {
      throw error;
    }
    return positionSecs;
  }

  @override
  Future<double> duration() async => durationSecs;

  @override
  Future<void> seek(double positionSecs) async {
    final Object? error = seekError;
    if (error != null) {
      throw error;
    }
    seekCalls.add(positionSecs);
    this.positionSecs = positionSecs;
  }

  @override
  Future<void> setVolume(double volume) async {
    volumeCalls.add(volume);
  }

  @override
  bool get isExclusive => exclusive;

  @override
  Future<void> setExclusive(bool value) async {
    exclusiveCalls += 1;
    final Object? error = exclusiveError;
    if (error != null) {
      throw error;
    }
    exclusive = value;
  }

  @override
  Future<String> outputInfo() async {
    outputInfoCalls += 1;
    return outputInfoText;
  }

  bool eqEnabled = false;
  List<double> eqGains = const <double>[];
  int eqCalls = 0;

  @override
  Future<void> setEqualizer({
    required bool enabled,
    required List<double> gains,
  }) async {
    eqCalls += 1;
    eqEnabled = enabled;
    eqGains = List<double>.of(gains);
  }
}
