import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show ByteData, FontLoader, rootBundle;

/// 随安装包分发的字体（目前只有 MiSans）是否加载成功。
///
/// 字体文件不进版本库，由 `scripts/setup-misans.ps1` 从官方下载到
/// `assets/fonts/misans/`；没跑过脚本的机器上这里会是 false，歌词字体选项里
/// 就不会出现 MiSans，其余功能一切照旧。
bool misansAvailable = false;

/// 打包字体的家族名：`TextStyle(fontFamily: 'MiSans')` 用的就是它
const String miSansFamily = 'MiSans';

/// 注册随安装包分发的字体；在 `runApp` 之前调一次。
///
/// 为什么要运行时注册而不是写进 `pubspec` 的 `fonts:`：字体文件是被 gitignore
/// 的，写进 `fonts:` 会让「没下载字体」的机器（包括 CI）构建直接失败；运行时
/// 用 [FontLoader] 读资产，缺文件只是注册不上，程序照常跑。
///
/// 同一家族注册多个字重：Regular（歌词正文 w400）+ Demibold（当前行 w600），
/// 免得大字号下靠合成粗体。
Future<void> registerBundledFonts() async {
  const List<String> assets = <String>[
    'assets/fonts/misans/MiSans-Regular.ttf',
    'assets/fonts/misans/MiSans-Demibold.ttf',
  ];
  final FontLoader loader = FontLoader(miSansFamily);
  int found = 0;
  for (final String asset in assets) {
    try {
      final ByteData data = await rootBundle.load(asset);
      loader.addFont(Future<ByteData>.value(data));
      found += 1;
    } catch (error) {
      // 没跑过 setup-misans.ps1：正常情况，不打扰用户
      debugPrint('跳过打包字体 $asset：$error');
    }
  }
  if (found == 0) {
    misansAvailable = false;
    return;
  }
  try {
    await loader.load();
    misansAvailable = true;
  } catch (error) {
    misansAvailable = false;
    debugPrint('注册打包字体失败：$error');
  }
}
