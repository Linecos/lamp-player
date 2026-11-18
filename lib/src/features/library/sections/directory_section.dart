part of '../library_page.dart';

/// 音乐目录与扫描导入
///
/// 从 `_LibraryPageState` 拆出，仍直接读写页面状态：这一轮只做文件切分。
extension _DirectorySection on _LibraryPageState {
  /// 当前分区自带扫描进度 / 结果面板：这两处不必再弹 toast，拖放导入
  /// 也要先把用户带回有曲目列表的分区。
  bool get _showsScanReport =>
      _section == LibrarySection.settings || _section == LibrarySection.library;

  /* ------------------------------------------------------------ 音乐目录 */

  Future<void> _loadFolders() async {
    final List<String> folders = await _folderStore.load();
    if (!mounted) {
      return;
    }
    _update(() => _folders = normalizeFolders(folders));
  }

  Future<void> _loadFoldersAndMaybeBackfill() async {
    await _loadFolders();
    await _backfillCoversIfNeeded();
  }

  /// 老库升级后补扫一次已添加目录（封面与音质原始量一起补）。
  ///
  /// 曲库升到 v3 后老曲目没有封面；升到 v10 后老曲目的 `file_size` /
  /// `sample_rate` / `bit_depth` 全是 0（迁移把指纹清零了，等重扫）。
  /// 两种都是「老库还没重扫」，扫一遍同时解决。
  ///
  /// 成败都记为「已尝试」，否则没有内嵌封面的曲库会每次启动都全量扫一遍。
  /// 音质缺失例外：迁移后第一次启动必须补一次，不能因为封面早试过就跳过，
  /// 否则音质分布永远是「全部未知」；扫过一次就有大小了，条件自然失效。
  ///
  /// **目录不可达时整轮跳过、也不记「已尝试」**：移动硬盘 / 网络盘没挂时扫了
  /// 个寂寞（`file_size` 还是 0），于是下次启动又满足条件、再全量扫一遍。
  /// 探一下目录在不在很便宜，盘挂回来时再补，也不丢这次机会。
  Future<void> _backfillCoversIfNeeded() async {
    if (!mounted || _scanning) {
      return;
    }
    if (_tracks.isEmpty || _folders.isEmpty) {
      return;
    }
    final bool missingQuality = _tracks.every(
      (Track track) => track.fileSize == 0,
    );
    if (_coverBackfillAttempted && !missingQuality) {
      return;
    }
    // 混合状态通常说明用户已经手动扫过一部分目录，不再自动全量重扫。
    final bool missingCovers = _tracks.every(
      (Track track) => track.coverPath == null,
    );
    if (!missingCovers && !missingQuality) {
      _update(() => _coverBackfillAttempted = true);
      unawaited(_saveSession());
      return;
    }
    final List<String> reachable = _folders
        .where((String folder) => Directory(folder).existsSync())
        .toList(growable: false);
    if (reachable.isEmpty) {
      return;
    }

    _update(() => _backfillingCovers = true);
    for (final String folder in reachable) {
      if (!mounted) {
        return;
      }
      await _scanDirectory(folder, notify: false);
    }
    if (!mounted) {
      return;
    }
    _update(() {
      _backfillingCovers = false;
      _coverBackfillAttempted = true;
    });
    unawaited(_saveSession());
  }

  /// 记下新目录（忽略大小写去重）；已存在时不重复写入。
  ///
  /// 持久化是"尽力而为"：不等待写完就开始扫描，避免磁盘/插件慢时拖住扫描。
  void _rememberFolder(String folder) {
    final List<String> next = normalizeFolders(<String>[..._folders, folder]);
    if (next.length == _folders.length) {
      return;
    }
    _update(() => _folders = next);
    unawaited(_folderStore.save(next));
  }

  /// 从列表移除目录：只删记录，不删除已入库的曲目。
  void _removeFolder(String folder) {
    final String key = folder.toLowerCase();
    final List<String> next = _folders
        .where((String item) => item.toLowerCase() != key)
        .toList();
    _update(() {
      _folders = next;
      if (_lastScanFolder?.toLowerCase() == key) {
        _lastScanFolder = null;
        _scanReport = null;
        _scanError = null;
      }
    });
    unawaited(_folderStore.save(next));
  }

  Future<void> _rescanFolder(String folder) async {
    if (_scanning) {
      return;
    }
    await _scanDirectory(folder);
  }

  Future<String?> _pickDirectory() {
    return getDirectoryPath(confirmButtonText: '选择音乐目录');
  }

  Future<void> _addMusicFolder() async {
    if (_scanning) {
      return;
    }

    final DirectoryPicker picker = widget.directoryPicker ?? _pickDirectory;
    String? folder;
    try {
      folder = await picker();
    } catch (error) {
      if (mounted) {
        _showMessage('选择目录失败：${ErrorRetry.describe(error)}');
      }
      return;
    }
    if (folder == null || folder.trim().isEmpty || !mounted) {
      return;
    }

    _rememberFolder(folder.trim());
    await _scanDirectory(folder.trim());
  }

  void _setDragging(bool value) {
    if (_dragging == value) {
      return;
    }
    _update(() => _dragging = value);
  }

  /// 拖入文件夹或音频文件：取它们所在的目录，复用已有的扫描与记忆流程。
  Future<void> _handleDrop(List<DropItem> files) async {
    if (!mounted) {
      return;
    }
    if (_scanning) {
      _showMessage('正在扫描，请稍后再拖入');
      return;
    }
    final List<String> folders = foldersFromDropPaths(
      files.map((DropItem file) => file.path),
    );
    if (folders.isEmpty) {
      _showMessage('没有可导入的音频文件或文件夹');
      return;
    }
    if (_showsScanReport) {
      _selectSection(LibrarySection.music);
    }

    int imported = 0;
    for (final String folder in folders) {
      _rememberFolder(folder);
      final bool ok = await _scanDirectory(folder, notify: false);
      if (!mounted) {
        return;
      }
      if (!ok) {
        final Object? error = _scanError;
        _showMessage(
          '导入失败：${error == null ? '未知错误' : ErrorRetry.describe(error)}',
        );
        return;
      }
      imported += 1;
    }
    if (!mounted) {
      return;
    }
    final scan.ScanReport? report = _scanReport;
    _showMessage(
      report == null
          ? '已导入 $imported 个目录'
          : '导入完成：$imported 个目录，更新 ${report.upserted} 首，'
                '失败 ${report.failed} 首',
    );
  }

  /// 扫描指定目录；设置页展示结果，空曲库时用 SnackBar 提示。
  ///
  /// 自动补扫时传 `notify: false`，避免多个目录各弹一次提示。
  Future<bool> _scanDirectory(String folder, {bool notify = true}) async {
    if (_scanning) {
      return false;
    }

    _update(() {
      _scanning = true;
      _lastScanFolder = folder;
      _scanReport = null;
      _scanError = null;
    });
    try {
      final scan.ScanReport report = await _repository.scanFolder(folder);
      await _loadTracks(silent: true);
      if (!mounted) {
        return false;
      }
      _update(() {
        _scanning = false;
        _scanReport = report;
      });
      if (!_backfillingCovers) {
        _coverBackfillAttempted = true;
        unawaited(_saveSession());
      }
      if (notify && !_showsScanReport) {
        _showMessage(
          '扫描完成：更新 ${report.upserted} 首，失败 ${report.failed} 首，'
          '清理 ${report.pruned} 首',
        );
      }
      return true;
    } catch (error) {
      if (!mounted) {
        return false;
      }
      _update(() {
        _scanning = false;
        _scanError = error;
      });
      if (!_backfillingCovers) {
        _coverBackfillAttempted = true;
        unawaited(_saveSession());
      }
      if (notify && !_showsScanReport) {
        _showMessage('扫描失败：${ErrorRetry.describe(error)}');
      }
      return false;
    }
  }
}
