import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 艺术家首字母头像。
///
/// 列表卡片（96）、详情头部（240）、飞行中的那一份、艺术家选择弹窗（36）
/// 都用它：字号跟着尺寸走，飞过去的过程中字不会跳大小。
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
