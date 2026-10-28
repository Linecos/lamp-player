part of '../library_page.dart';

/// 设置分区
///
/// 从 `_LibraryPageState` 拆出，仍直接读写页面状态：这一轮只做文件切分。
extension _SettingsSection on _LibraryPageState {
  Widget _buildSettingsSection(BuildContext context) {
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
