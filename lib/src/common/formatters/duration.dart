/// 秒 → `mm:ss`；满一小时用 `h:mm:ss`（`3837` → `1:03:57`）。
library;

String formatDuration(double seconds) {
  final int totalSeconds = _toWholeSeconds(seconds);
  final int hours = totalSeconds ~/ 3600;
  final int minutes = (totalSeconds % 3600) ~/ 60;
  final int secs = totalSeconds % 60;
  final String minuteSecond = '${_pad(minutes)}:${_pad(secs)}';

  return hours > 0 ? '$hours:$minuteSecond' : minuteSecond;
}

/// 紧凑形式，始终省略小时（`3837` → `63:57`），用于窄区域。
String formatDurationCompact(double seconds) {
  final int totalSeconds = _toWholeSeconds(seconds);
  return '${_pad(totalSeconds ~/ 60)}:${_pad(totalSeconds % 60)}';
}

// 四舍五入到整秒；负数、NaN、Infinity 归零
int _toWholeSeconds(double seconds) {
  if (seconds.isNaN || seconds.isInfinite || seconds <= 0) {
    return 0;
  }
  final int rounded = seconds.round();
  return rounded < 0 ? 0 : rounded;
}

String _pad(int value) => value.toString().padLeft(2, '0');
