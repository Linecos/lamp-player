import 'package:flutter/foundation.dart';

/// 曲库内容在别处被改动时自增的版本号。
///
/// 设置页里的「恢复隐藏的歌曲」和曲库页不在同一棵子树里，没有共同祖先可以
/// 回调；用一个进程内的通知器最省事。曲库页监听它重新拉取曲目与歌单，
/// 恢复完的歌才会立刻出现在列表里（以前要手动重新扫描或重启）。
final ValueNotifier<int> libraryRevision = ValueNotifier<int>(0);

/// 标记曲库内容已变化：曲目、歌单曲目数、收藏等都可能受影响。
void markLibraryChanged() => libraryRevision.value += 1;
