part of '../library_page.dart';

/// 检查更新：手动触发、启动时按频率自动检查。
extension _UpdateSection on _LibraryPageState {
  /// 自动检查入口：没开开关、正在检查、或还没到点都直接返回。
  ///
  /// 只在启动时会话恢复完之后调用一次；改开关本身不触发检查。
  Future<void> _maybeAutoCheckUpdates() async {
    if (!mounted || !_autoUpdateCheck || _checkingUpdate) {
      return;
    }
    if (!_updatePeriod.isDue(_lastUpdateCheckAt, DateTime.now())) {
      return;
    }
    await _checkUpdates(manual: false);
  }

  /// 真正查一次。手动检查会把「已是最新 / 失败」用轻提示回一句；
  /// 自动检查只有发现新版本才弹窗，其余情况悄悄收场。
  Future<void> _checkUpdates({required bool manual}) async {
    if (_checkingUpdate) {
      return;
    }
    _update(() => _checkingUpdate = true);
    final UpdateCheckOutcome outcome = await checkForUpdate();
    if (!mounted) {
      return;
    }
    _update(() {
      _checkingUpdate = false;
      _updateAvailable = outcome.hasUpdate;
      if (outcome.hasUpdate) {
        _updateStatus = '发现新版本 v${outcome.release!.version}';
      } else if (outcome.failed) {
        _updateStatus = '检查失败：${outcome.error}';
      } else {
        _updateStatus = '已是最新（v${outcome.latestVersion}）';
      }
    });

    if (outcome.hasUpdate) {
      _markCheckedNow();
      await showUpdateAvailableDialog(context, outcome.release!);
      return;
    }

    if (outcome.failed) {
      // 失败不记「查过了」：网络恢复后下次启动还能再试
      if (manual) {
        AppToast.show(context, '检查更新失败：${outcome.error}');
      }
      return;
    }

    _markCheckedNow();
    if (manual) {
      AppToast.show(context, '已是最新版本（v${outcome.latestVersion}）');
    }
  }

  void _markCheckedNow() {
    _lastUpdateCheckAt = DateTime.now();
    _saveSessionNow();
  }
}
