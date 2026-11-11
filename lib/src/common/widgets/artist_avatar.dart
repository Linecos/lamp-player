import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'album_cover.dart';

/// 艺术家头像：**有封面就用封面**，没有才回退到首字母。
///
/// 封面来自这位艺术家曲库里第一首有封面的曲目（`ArtistGroup.coverPath`）。
/// 列表卡片（96）、详情头部（240）、飞行中的那一份都走这里，两端的圆形
/// 与裁切方式因此完全一致，飞过去不会「中途换个形状」。
///
/// 圆形**必须**自己套 [ClipOval]，不能给 [AlbumCover] 传 `circular: true`：
/// 那个参数的意思是「跟随设置里的圆形封面开关」，用户把它关掉时艺术家头像
/// 会跟着变成圆角方块。也不能写成 `ClipRRect(size / 2)`——飞行层会把这张图
/// 塞进任意尺寸的紧约束，半径按声明尺寸算出来就是「圆角方块」（退出播放页
/// 时那个 bug 就是这么来的）。`ClipOval` 跟着实际尺寸走，盒子被拉多大都是正圆。
Widget artistAvatar(
  BuildContext context,
  String name,
  double size, {
  String? coverPath,
}) {
  final String? path = coverPath?.trim();
  if (path != null && path.isNotEmpty) {
    // 内层圆角给 0：形状完全由外层 ClipOval 决定，避免两层各自裁一次
    return ClipOval(
      child: AlbumCover(path: path, size: size, radius: 0),
    );
  }
  return artistInitialsAvatar(context, name, size);
}

/// 艺术家首字母头像。
///
/// 只在没有可用封面时出场：列表卡片、详情头部、飞行中的那一份、
/// 艺术家选择弹窗（36）都用它——字号跟着尺寸走，飞过去的过程中字不会跳大小。
///
/// 字号取尺寸的 0.22，但**有下限 14**：小圆（36）按比例只有 8px，
/// 一个中文字在那种尺寸下读不出来。
Widget artistInitialsAvatar(BuildContext context, String name, double size) {
  final ThemeData theme = Theme.of(context);
  final ColorScheme scheme = theme.colorScheme;
  return Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      color: scheme.primaryContainer,
    ),
    alignment: Alignment.center,
    child: Text(
      initialsOf(name),
      style: theme.textTheme.headlineSmall?.copyWith(
        fontSize: math.max(size * 0.22, 14),
        color: scheme.onPrimaryContainer,
      ),
    ),
  );
}

/// 取展示用首字：中文取第一个字，英文取首字母。
String initialsOf(String name) {
  final String text = name.trim();
  if (text.isEmpty) {
    return '?';
  }
  return String.fromCharCode(text.runes.first).toUpperCase();
}
