import 'dart:io';

/// 用系统默认浏览器打开一个链接。
///
/// 不引 `url_launcher`：本项目只发 Windows，`rundll32 url.dll,FileProtocolHandler`
/// 走的就是 ShellExecute——不弹控制台窗口，也不用处理 `cmd start` 那套引号转义。
/// 返回值只表示「有没有把请求递出去」，浏览器起没起来不在这里判断。
typedef OpenExternalUrl = Future<bool> Function(String url);

Future<bool> openExternalUrl(String url) async {
  if (!url.startsWith('https://') && !url.startsWith('http://')) {
    return false;
  }
  if (!Platform.isWindows) {
    return false;
  }
  try {
    await Process.start('rundll32', <String>[
      'url.dll,FileProtocolHandler',
      url,
    ], mode: ProcessStartMode.detached);
    return true;
  } on ProcessException {
    return false;
  }
}
