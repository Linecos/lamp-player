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
            exclusive: _exclusive,
            exclusiveActive: _playback.isExclusive,
            switchingOutput: _switchingOutput,
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
            lyricFont: _lyricFontFamily,
            onLyricFontChanged: (String family) =>
                unawaited(_setLyricFontFamily(family)),
            lyricBlur: _lyricBlur,
            onLyricBlurChanged: _setLyricBlur,
            lyricSpring: _lyricSpring,
            onLyricSpringChanged: _setLyricSpring,
            // 界面字体存在主题控制器里；换过之后要把新字体重推给桌面歌词
            onInterfaceFontChanged: () =>
                unawaited(_syncDesktopLyricFontFamily()),
            outputDevice: _outputDevice,
            onOutputDeviceChanged: _isAvailable && !_switchingOutput
                ? (int index) => unawaited(_setOutputDevice(index))
                : null,
            replayGain: _replayGain,
            onReplayGainChanged: _setReplayGain,
            replayGainReference: _replayGainReference,
            onReplayGainReferenceChanged: _setReplayGainReference,
            replayGainTruePeak: _replayGainTruePeak,
            onReplayGainTruePeakChanged: _setReplayGainTruePeak,
            crossfadeEnabled: _crossfadeSeconds > 0,
            crossfadeSeconds: _crossfadeSeconds > 0
                ? _crossfadeSeconds
                : _lastCrossfadeSeconds,
            onCrossfadeEnabledChanged: _isAvailable
                ? (bool enabled) => unawaited(_setCrossfadeEnabled(enabled))
                : null,
            onCrossfadeChanged: _isAvailable
                ? (double seconds) => unawaited(_setCrossfade(seconds))
                : null,
            volumeFade: _volumeFade,
            onVolumeFadeChanged: _isAvailable ? _setVolumeFade : null,
            shortcuts: _shortcuts,
            onShowShortcuts: () => unawaited(_openShortcuts()),
            flowBackground: _flowBackground,
            onFlowBackgroundChanged: _setFlowBackground,
            circularCovers: _circularCovers,
            onCircularCoversChanged: _setCircularCovers,
            autoUpdateCheck: _autoUpdateCheck,
            onAutoUpdateCheckChanged: _setAutoUpdateCheck,
            updateCheckPeriod: _updatePeriod,
            onUpdateCheckPeriodChanged: _setUpdateCheckPeriod,
            checkingUpdate: _checkingUpdate,
            updateStatus: _updateStatus,
            onCheckUpdate: () => unawaited(_checkUpdates(manual: true)),
            // 底部播放岛是浮层：列表末尾要让出它的高度，「关于」才滚得出来
            bottomPadding: PlayerBar.occupiedHeight + 8,
            onExclusiveChanged: _isAvailable && !_switchingOutput
                ? (bool value) => unawaited(_setExclusive(value))
                : null,
            query: _query,
            matcher: _matchesText,
            onClearSearch: _clearSearch,
          ),
        ),
      ],
    );
  }

  /// 打开快捷键弹窗：录制式改键，点一行再按组合键
  Future<void> _openShortcuts() async {
    await showShortcutsDialog(
      context,
      bindings: _shortcuts,
      onChanged: _setShortcuts,
    );
  }

  /// 改键后立刻重绑（`CallbackShortcuts` 跟着 build 更新）并写回会话
  void _setShortcuts(List<ShortcutBinding> bindings) {
    _update(() => _shortcuts = bindings);
    _saveSessionNow();
  }

  void _setAutoUpdateCheck(bool value) {
    // 开关本身只决定「以后启动查不查」，不在这里立刻发请求
    _update(() => _autoUpdateCheck = value);
    _saveSessionNow();
  }

  void _setUpdateCheckPeriod(UpdateCheckPeriod value) {
    _update(() => _updatePeriod = value);
    _saveSessionNow();
  }
}
