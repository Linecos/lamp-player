part of '../library_page.dart';

/// 设置分区
///
/// 从 `_LibraryPageState` 拆出，仍直接读写页面状态：这一轮只做文件切分。
extension _SettingsSection on _LibraryPageState {
  Widget _buildSettingsSection(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final double total = _tracks.fold<double>(
      0,
      (double sum, Track track) => sum + track.durationSecs,
    );

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
            totalDurationSecs: total,
            engineAvailable: _isAvailable,
            exclusive: _exclusive,
            exclusiveActive: _playback.isExclusive,
            switchingOutput: _switchingOutput,
            outputInfo: _outputInfo,
            closeToTray: widget.appLifecycle?.closeToTray ?? true,
            onCloseToTrayChanged: widget.appLifecycle == null
                ? null
                : (bool value) => widget.appLifecycle!.closeToTray = value,
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
          ),
        ),
      ],
    );
  }
}
