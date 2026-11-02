part of '../library_page.dart';

/// 设置分区
///
/// 从 `_LibraryPageState` 拆出，仍直接读写页面状态：这一轮只做文件切分。
extension _SettingsSection on _LibraryPageState {
  Widget _buildSettingsSection(BuildContext context) {
    final bool statsOpen = _settingsStatsOpen;

    // 设置列表 ↔ 统计子界面之间做个淡入上滑：直接换掉太突兀，而这个过渡
    // 只动不透明度与位移，两份子树各自 RepaintBoundary，不会每帧重画。
    // 只在切换的 180ms 里两者共存，之后仍然是一份，和「不常驻」一致。
    return AnimatedSwitcher(
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
            // 位移只给 1.5%（约 10px）：淡入一点点上浮就够，别做成整页平移
            position: Tween<Offset>(
              begin: const Offset(0, 0.015),
              end: Offset.zero,
            ).animate(animation),
            child: child,
          ),
        );
      },
      child: KeyedSubtree(
        // key 一变才会触发过渡；两种内容的根 key 必须不同
        key: ValueKey<bool>(statsOpen),
        // 各包一层绘制边界：淡入淡出就只是图层透明度变化，不必每帧把整块
        // 内容重新光栅化
        child: RepaintBoundary(
          child: statsOpen ? _buildStatsSubView() : _buildSettingsList(context),
        ),
      ),
    );
  }

  /// 听歌统计子界面。
  ///
  /// 子界面而不是新页面：左侧栏与底部播放岛都还在（它们本来就是外层的）。
  /// 条件构建 = 打开才查库、关闭即销毁，不留后台开销。
  Widget _buildStatsSubView() {
    return ListeningStatsView(
      key: const ValueKey<String>('settings-stats'),
      repository: widget.statsRepository,
      onBack: () => _update(() => _settingsStatsOpen = false),
      onPlayTrack: (List<Track> queue, Track track) =>
          unawaited(_playFrom(queue, track)),
      onOpenArtist: _openArtistFromStats,
      // 播放岛是浮层：最后一行得能滚到它上面
      bottomPadding: PlayerBar.occupiedHeight + 8,
    );
  }

  Widget _buildSettingsList(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(
          '设置',
          style: theme.textTheme.headlineMedium?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 2),
        Expanded(
          child: SettingsView(
            trackCount: _tracks.length,
            onOpenStats: () => _update(() => _settingsStatsOpen = true),
            engineAvailable: _isAvailable,
            exclusive: _exclusive,
            exclusiveActive: _playback.isExclusive,
            switchingOutput: _switchingOutput,
            outputInfo: _outputInfo,
            closeToTray: widget.appLifecycle?.closeToTray ?? true,
            onCloseToTrayChanged: widget.appLifecycle == null
                ? null
                : (bool value) => widget.appLifecycle!.closeToTray = value,
            eqEnabled: _eqEnabled,
            eqGains: _eqGains,
            eqPresetName: _eqPresetName,
            eqCustomPresets: _eqCustomPresets,
            onEqualizerChanged: _isAvailable ? _setEqualizer : null,
            onEqPresetsChanged: _setEqCustomPresets,
            devices: _devices,
            outputDevice: _outputDevice,
            onOutputDeviceChanged: _isAvailable && !_switchingOutput
                ? (int index) => unawaited(_setOutputDevice(index))
                : null,
            replayGain: _replayGain,
            onReplayGainChanged: _setReplayGain,
            crossfadeSeconds: _crossfadeSeconds,
            onCrossfadeChanged: _isAvailable
                ? (double seconds) => unawaited(_setCrossfade(seconds))
                : null,
            shortcuts: _shortcuts,
            onShowShortcuts: () => unawaited(_openShortcuts()),
            flowBackground: _flowBackground,
            onFlowBackgroundChanged: _setFlowBackground,
            circularCovers: _circularCovers,
            onCircularCoversChanged: _setCircularCovers,
            // 底部播放岛是浮层：列表末尾要让出它的高度，「关于」才滚得出来
            bottomPadding: PlayerBar.occupiedHeight + 8,
            onExclusiveChanged: _isAvailable && !_switchingOutput
                ? (bool value) => unawaited(_setExclusive(value))
                : null,
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
            query: _query,
            matcher: _matchesText,
            onClearSearch: _clearSearch,
          ),
        ),
      ],
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

  /// 打开快捷键设置页：录制式改键，点一行再按组合键
  Future<void> _openShortcuts() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (BuildContext context) =>
            ShortcutsPage(bindings: _shortcuts, onChanged: _setShortcuts),
      ),
    );
  }

  /// 改键后立刻重绑（`CallbackShortcuts` 跟着 build 更新）并写回会话
  void _setShortcuts(List<ShortcutBinding> bindings) {
    _update(() => _shortcuts = bindings);
    _saveSessionNow();
  }
}
