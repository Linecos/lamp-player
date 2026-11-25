part of '../library_page.dart';

/// 音乐库分区
///
/// 目录管理、隐藏与清理原先塞在设置页里，现在独立成一个分区；「听歌统计」
/// 也跟着搬过来，作为这个分区内部的子界面（侧栏与播放岛都不动）。
extension _LibrarySection on _LibraryPageState {
  /// 进入音乐库分区时预热一次听歌统计。

  void _prefetchStatsOnce() {
    if (_statsPrefetched) {
      return;
    }
    _statsPrefetched = true;
    prefetchListeningStats(repository: widget.statsRepository);
  }

  Widget _buildLibrarySection(BuildContext context) {
    final bool statsOpen = _libraryStatsOpen;
    final AudioQuality? quality = _qualityDetail;
    final String? folder = _folderDetail;

    // 与设置页原来那套一样：列表 ↔ 子界面之间淡入上滑，两份子树各自
    // RepaintBoundary，过渡的 180ms 里才共存。
    //
    // 切换器不能靠换 key 重建：分区切走再切回来的第一次点击正好赶上重建，
    // 旧页面就不会参与过渡（「切回来第一次点音质没有动画」）。
    return SubPageSwitcher(
      jumpToken: _sectionEpochs[LibrarySection.library] ?? 0,
      child: KeyedSubtree(
        key: ValueKey<String>(
          'library-$statsOpen-${quality?.name ?? ''}-${folder ?? ''}',
        ),
        child: RepaintBoundary(
          child: statsOpen
              ? _buildStatsSubView()
              : quality != null
              ? _buildQualityDetail(context)
              : folder != null
              ? _buildFolderDetail(context)
              : _buildLibraryHome(context),
        ),
      ),
    );
  }

  /// 音乐库列表：曲目数量、目录、隐藏与清理
  Widget _buildLibraryHome(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        // 页头只留标题：添加目录的入口在「音乐目录」块的 + 上，不必占两处
        Text(
          '音乐库',
          style: theme.textTheme.headlineMedium?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 2),
        Expanded(
          child: LibraryManageView(
            tracks: _tracks,
            onOpenStats: () => _update(() => _libraryStatsOpen = true),
            // 只有慢扫描才画「正在扫描」：短扫描的那一帧副标题会闪
            scanning: _scanSlow,
            folders: _folders,
            onAddFolder: _scanning ? null : () => unawaited(_addMusicFolder()),
            onOpenFolder: (String folder) => _openFolderDetail(folder),
            // 指标卡当入口用：点「曲目 / 专辑 / 艺术家」直接切分区
            onOpenTracks: () => _selectSection(LibrarySection.music),
            onOpenAlbums: () => _selectSection(LibrarySection.albums),
            onOpenArtists: () => _selectSection(LibrarySection.artists),
            onRescanFolder: _scanning
                ? null
                : (String folder) => unawaited(_rescanFolder(folder)),
            onRemoveFolder: _scanning ? null : _removeFolder,
            scanFolder: _lastScanFolder,
            scanError: _scanError,
            onRetry: _scanning || _lastScanFolder == null
                ? null
                : () => unawaited(_scanDirectory(_lastScanFolder!)),
            pruningMissing: _pruningMissing,
            prunedMissingCount: _prunedMissingCount,
            pruneMissingError: _pruneMissingError,
            onPruneMissing: _pruningMissing
                ? null
                : () => unawaited(_pruneMissing()),
            // 播放岛是浮层：最后一行得能滚到它上面
            bottomPadding: PlayerBar.occupiedHeight + 8,
            query: _query,
            qualityBreakdown: _qualityBreakdown,
            qualitySelected: _qualityDetail,
            onSelectQuality: _openQualityDetail,
          ),
        ),
      ],
    );
  }

  /// 听歌统计子界面。
  ///
  /// 子界面而不是新页面：左侧栏与底部播放岛都还在（它们本来就是外层的）。
  /// 条件构建 = 打开才查库、关闭即销毁，不留后台开销。
  Widget _buildStatsSubView() {
    return ListeningStatsView(
      key: const ValueKey<String>('library-stats'),
      repository: widget.statsRepository,
      onBack: () => _update(() => _libraryStatsOpen = false),
      onPlayTrack: (List<Track> queue, Track track) =>
          unawaited(_playFrom(queue, track)),
      onOpenArtist: _openArtistFromStats,
      bottomPadding: PlayerBar.occupiedHeight + 8,
    );
  }

  /// 清理磁盘上已不存在的曲库记录。
  ///
  /// 存储层会拒绝「疑似整块磁盘未挂载」的情况（例如所有记录同时消失），
  /// 这里必须把错误展示出来，不能当成「清理 0 条」。
  Future<void> _pruneMissing() async {
    if (_pruningMissing) {
      return;
    }
    _update(() {
      _pruningMissing = true;
      _prunedMissingCount = null;
      _pruneMissingError = null;
    });
    try {
      final Set<String> before = _tracks
          .map((Track track) => track.path)
          .toSet();
      final int removed = await _repository.pruneMissingTracks();
      if (!mounted) {
        return;
      }
      if (removed > 0) {
        await _loadTracks(silent: true);
        if (!mounted) {
          return;
        }
        final Set<String> after = _tracks
            .map((Track track) => track.path)
            .toSet();
        _applyRemovedPaths(before.difference(after));
      }
      _update(() {
        _pruningMissing = false;
        _prunedMissingCount = removed;
      });
      _showMessage(removed > 0 ? '已清理 $removed 条缺失记录' : '没有发现缺失文件');
    } catch (error) {
      if (!mounted) {
        return;
      }
      _update(() {
        _pruningMissing = false;
        _pruneMissingError = error;
      });
      _showMessage('清理失败：${ErrorRetry.describe(error)}');
    }
  }
}
