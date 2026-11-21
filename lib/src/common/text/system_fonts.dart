import 'package:flutter/foundation.dart';

import '../../rust/api/fonts.dart' as rust;

/// 本机已安装的字体族名，进程内只取一次。
///
/// 枚举走 Rust（读字体文件的 name 表，见 `rust/src/system_fonts.rs`）：字体
/// 文件加起来几十 MB，每次开弹窗都扫一遍太慢，所以 Rust 侧缓存、这里再缓存
/// 一层 Future。读取失败时退到空表，弹窗会改用内置的中文字体表兜底。
List<String>? _cache;

Future<List<String>> systemFontFamilies() {
  final List<String>? cached = _cache;
  if (cached != null) {
    return SynchronousFuture<List<String>>(cached);
  }
  return _load();
}

Future<List<String>> _load() async {
  List<String> families;
  try {
    families = await rust.installedFontFamilies();
  } catch (error) {
    // 桥接还没初始化（单元测试）或系统目录读不到：不抛给界面，列表照样能用
    debugPrint('读取本机字体失败：$error');
    families = const <String>[];
  }
  _cache = families;
  return families;
}

/// 清掉缓存，让下次重新枚举（测试用）
@visibleForTesting
void resetSystemFontCache() {
  _cache = null;
}
