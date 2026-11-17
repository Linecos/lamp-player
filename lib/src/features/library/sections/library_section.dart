part of '../library_page.dart';

/// 音乐库分区
///
/// 目录管理、隐藏与清理原先塞在设置页里，现在独立成一个分区；「听歌统计」
/// 也跟着搬过来，作为这个分区内部的子界面（侧栏与播放岛都不动）。
extension _LibrarySection on _LibraryPageState {
  Widget _buildLibrarySection(BuildContext context) {
    final bool statsOpen = _libraryStatsOpen;

    // 与设置页原来那套一样：列表 ↔ 子界面之间淡入上滑，两份子树各自
    // RepaintBoundary，过渡的 180ms 里才共存。
    //
    // key 带分区世代：从别的分区切回来时换一个新的，免得它记着切走前的
    // 统计页再淡出 180ms。
    return AnimatedSwitcher(
      key: ValueKey<String>(
        'library-epoch-${_sectionEpochs[LibrarySection.library] ?? 0}',
      ),
      duration: const Duration(milliseconds: 180),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      layoutBuilder: (Widget? current, List<Widget> previous) => Stack(
        fit: StackFit.expand,
        children: <Widget>[...previous, ?current],
      ),
      transitionBuilder: (Widget child, Animation<double> animation) {
        return FadeTransition(
          opacity: animation,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, 0.015),
              end: Offset.zero,
            ).animate(animation),
            child: child,
          ),
        );
      },
      child: KeyedSubtree(
        key: ValueKey<String>('library-$statsOpen'),
        child: RepaintBoundary(
          child: statsOpen ? _buildStatsSubView() : _buildLibraryHome(context),
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
        Row(
          children: <Widget>[
            Text(
              '音乐库',
              style: theme.textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const Spacer(),
            _ToolPill(
              key: const ValueKey<String>('library-add-folder'),
              label: '添加音乐目录',
              onTap: _scanning ? null : () => unawaited(_addMusicFolder()),
            ),
          ],
        ),
        const SizedBox(height: 2),
        Expanded(
          child: LibraryManageView(
            tracks: _tracks,
            onOpenStats: () => _update(() => _libraryStatsOpen = true),
            scanning: _scanning,
            folders: _folders,
            onAddFolder: _scanning ? null : () => unawaited(_addMusicFolder()),
            onRescanFolder: _scanning
                ? null
                : (String folder) => unawaited(_rescanFolder(folder)),
            onRemoveFolder: _scanning ? null : _removeFolder,
            scanFolder: _lastScanFolder,
            scanReport: _scanReport,
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

/// 页头右侧的胶囊按钮
class _ToolPill extends StatefulWidget {
  const _ToolPill({super.key, required this.label, this.onTap});

  final String label;
  final VoidCallback? onTap;

  @override
  State<_ToolPill> createState() => _ToolPillState();
}

class _ToolPillState extends State<_ToolPill> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final bool enabled = widget.onTap != null;
    // 悬停 / 聚焦才点亮：整颗胶囊变底色 + 描边与文字转强调色
    final bool lit = enabled && (_hovered || _focused);

    return Material(
      color: lit ? scheme.surfaceContainerHigh : Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(999),
        side: BorderSide(
          color: lit
              ? scheme.primary
              : enabled
              ? scheme.outline
              : scheme.outlineVariant,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: widget.onTap,
        onHover: (bool value) => setState(() => _hovered = value),
        onFocusChange: (bool value) => setState(() => _focused = value),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          child: Text(
            widget.label,
            style: theme.textTheme.bodySmall?.copyWith(
              color: !enabled
                  ? scheme.outline
                  : lit
                  ? scheme.primary
                  : scheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }
}
