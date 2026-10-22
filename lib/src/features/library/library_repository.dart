import '../../rust/api/db.dart' as db;
import '../../rust/api/model.dart';

/// 曲库读取接口。
///
/// 抽成接口只为一件事：`test/` 下的 widget 测试不依赖原生库（CI 底线）。
/// 生产路径永远走 [RustLibraryRepository]，不引入额外数据层。
abstract interface class LibraryRepository {
  /// 全量曲目（Rust 侧已按艺术家 / 专辑 / 曲号排序）
  Future<List<Track>> loadTracks();

  /// 全文检索；空查询由实现方返回空列表（契约如此）
  Future<List<Track>> searchTracks(String query, {int limit = 500});
}

class RustLibraryRepository implements LibraryRepository {
  const RustLibraryRepository();

  @override
  Future<List<Track>> loadTracks() => db.allTracks();

  @override
  Future<List<Track>> searchTracks(String query, {int limit = 500}) =>
      db.searchTracks(query: query, limit: limit);
}
