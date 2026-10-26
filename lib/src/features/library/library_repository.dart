import '../../rust/api/collections.dart' as collections;
import '../../rust/api/db.dart' as db;
import '../../rust/api/model.dart';
import '../../rust/api/scan.dart' as scan;

/// 曲库数据源接口：读取、搜索与目录扫描。
///
/// 抽成接口只为一件事：`test/` 下的 widget 测试不依赖原生库（CI 底线）。
/// 生产路径永远走 [RustLibraryRepository]，不引入额外数据层。
abstract interface class LibraryRepository {
  /// 全量曲目（Rust 侧已按艺术家 / 专辑 / 曲号排序）
  Future<List<Track>> loadTracks();

  /// 全文检索；空查询由实现方返回空列表（契约如此）
  Future<List<Track>> searchTracks(String query, {int limit = 500});

  /// 扫描目录并入库，返回本次扫描统计
  Future<scan.ScanReport> scanFolder(String folder);

  /// 歌单列表（带曲目数），按名称排序
  Future<List<Playlist>> loadPlaylists();

  /// 新建歌单；名称会去空白，重名 / 空名抛异常
  Future<Playlist> createPlaylist(String name);

  /// 重命名歌单；重名 / 空名抛异常
  Future<void> renamePlaylist(int id, String name);

  /// 删除歌单（歌单内条目由存储层级联清理）
  Future<void> deletePlaylist(int id);

  /// 歌单内曲目，按加入顺序
  Future<List<Track>> loadPlaylistTracks(int id);

  /// 加入歌单；已在歌单内返回 `false`
  Future<bool> addTrackToPlaylist(int id, String path);

  /// 批量加入歌单；返回真正新增的条数（已在歌单内的忽略）
  Future<int> addTracksToPlaylist(int id, List<String> paths);

  /// 移出歌单；本来就不在歌单内返回 `false`
  Future<bool> removeTrackFromPlaylist(int id, String path);

  /// 从曲库移除记录（只删记录，不删音频文件）；返回实际删除数
  Future<int> removeTracks(List<String> paths);

  /// 清理磁盘上已不存在的曲库记录；返回清理条数
  Future<int> pruneMissingTracks();

  /// 收藏的曲目，最近收藏的在前
  Future<List<Track>> loadFavorites();

  /// 全部收藏路径，供列表页一次拉取后做成员判断
  Future<Set<String>> loadFavoritePaths();

  Future<bool> isFavorite(String path);

  /// 设置收藏状态（幂等）
  Future<void> setFavorite(String path, bool favorite);

  /// 批量设置收藏状态；返回真正改变的条数
  Future<int> setFavorites(List<String> paths, bool favorite);

  /// 记录一次播放；同曲目只保留一条历史
  Future<void> recordPlay(String path);

  /// 累加某首歌在 [day]（`yyyyMMdd` 整数）的播放秒数
  Future<void> recordPlayTime(String path, int day, int seconds);

  /// 最近播放的曲目（按曲目去重），`limit` 由存储层截断
  Future<List<Track>> loadRecentTracks({int limit = 100});

  /// 清空播放历史
  Future<void> clearHistory();
}

class RustLibraryRepository implements LibraryRepository {
  const RustLibraryRepository();

  @override
  Future<List<Track>> loadTracks() => db.allTracks();

  @override
  Future<List<Track>> searchTracks(String query, {int limit = 500}) =>
      db.searchTracks(query: query, limit: limit);

  @override
  Future<scan.ScanReport> scanFolder(String folder) =>
      scan.scanFolder(folder: folder);

  @override
  Future<List<Playlist>> loadPlaylists() => collections.listPlaylists();

  @override
  Future<Playlist> createPlaylist(String name) =>
      collections.createPlaylist(name: name);

  @override
  Future<void> renamePlaylist(int id, String name) =>
      collections.renamePlaylist(id: id, name: name);

  @override
  Future<void> deletePlaylist(int id) => collections.deletePlaylist(id: id);

  @override
  Future<List<Track>> loadPlaylistTracks(int id) =>
      collections.playlistTracks(id: id);

  @override
  Future<bool> addTrackToPlaylist(int id, String path) =>
      collections.addTrackToPlaylist(id: id, path: path);

  @override
  Future<int> addTracksToPlaylist(int id, List<String> paths) =>
      collections.addTracksToPlaylist(id: id, paths: paths);

  @override
  Future<bool> removeTrackFromPlaylist(int id, String path) =>
      collections.removeTrackFromPlaylist(id: id, path: path);

  @override
  Future<int> removeTracks(List<String> paths) => db.removeTracks(paths: paths);

  @override
  Future<int> pruneMissingTracks() => db.pruneMissingTracks();

  @override
  Future<List<Track>> loadFavorites() => collections.listFavorites();

  @override
  Future<Set<String>> loadFavoritePaths() async =>
      (await collections.favoritePaths()).toSet();

  @override
  Future<bool> isFavorite(String path) => collections.isFavorite(path: path);

  @override
  Future<void> setFavorite(String path, bool favorite) =>
      collections.setFavorite(path: path, favorite: favorite);

  @override
  Future<int> setFavorites(List<String> paths, bool favorite) =>
      collections.setFavorites(paths: paths, favorite: favorite);

  @override
  Future<void> recordPlay(String path) => collections.recordPlay(path: path);

  @override
  Future<void> recordPlayTime(String path, int day, int seconds) =>
      collections.recordPlayTime(path: path, day: day, seconds: seconds);

  @override
  Future<List<Track>> loadRecentTracks({int limit = 100}) =>
      collections.recentTracks(limit: limit);

  @override
  Future<void> clearHistory() => collections.clearHistory();
}
