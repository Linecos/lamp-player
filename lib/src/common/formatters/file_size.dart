/// 字节 → `1.45 MB`（1024 进制，去掉末尾多余的 0）。
library;

const List<String> _units = <String>['B', 'KB', 'MB', 'GB', 'TB', 'PB'];

String formatFileSize(int bytes) {
  if (bytes <= 0) {
    return '0 B';
  }
  if (bytes < 1024) {
    return '$bytes B';
  }

  double value = bytes.toDouble();
  int unitIndex = 0;
  while (value >= 1024 && unitIndex < _units.length - 1) {
    value /= 1024;
    unitIndex += 1;
  }

  return '${_trimTrailingZeros(value.toStringAsFixed(2))} ${_units[unitIndex]}';
}

String _trimTrailingZeros(String text) {
  if (!text.contains('.')) {
    return text;
  }
  String result = text;
  while (result.endsWith('0')) {
    result = result.substring(0, result.length - 1);
  }
  if (result.endsWith('.')) {
    result = result.substring(0, result.length - 1);
  }
  return result;
}
