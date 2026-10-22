import 'package:file_selector/file_selector.dart';

import '../../rust/api/scan.dart' as rust;

/// 目录选择 + 扫描的抽象。
///
/// 抽成接口是为了 `test/` 不依赖系统对话框与原生库（CI 底线），
/// 生产路径永远走 [PlatformScanService]。
abstract interface class LibraryScanService {
  /// 让用户选一个目录；用户取消时返回 null。
  Future<String?> pickFolder();

  Future<rust.ScanReport> scanFolder(String folder);
}

class PlatformScanService implements LibraryScanService {
  const PlatformScanService();

  @override
  Future<String?> pickFolder() => getDirectoryPath(confirmButtonText: '扫描此目录');

  @override
  Future<rust.ScanReport> scanFolder(String folder) =>
      rust.scanFolder(folder: folder);
}
