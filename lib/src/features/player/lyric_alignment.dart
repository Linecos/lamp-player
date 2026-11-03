import 'package:flutter/material.dart';

/// 歌词在歌词区里的水平对齐方式。
///
/// 只影响「一行文字摆在哪儿」，行与行之间的垂直排布、居中滚动逻辑都不变：
/// 换行时仍然把当前行的正文中心推到对齐线上。
enum LyricAlignment {
  center('居中', Icons.format_align_center),
  left('左对齐', Icons.format_align_left),
  right('右对齐', Icons.format_align_right);

  const LyricAlignment(this.label, this.icon);

  /// 界面上显示的名字（tooltip 用）
  final String label;

  /// 当前状态下按钮上画的图标
  final IconData icon;

  /// 点一下切到的下一档：居中 → 左 → 右 → 居中
  LyricAlignment get next => switch (this) {
    center => left,
    left => right,
    right => center,
  };

  /// 单行文字在整行宽度里的对齐
  TextAlign get textAlign => switch (this) {
    center => TextAlign.center,
    left => TextAlign.left,
    right => TextAlign.right,
  };

  /// 整块文字的落点：单行时文字宽度就是自身宽度，靠这个把整块推到左 / 中 / 右
  Alignment get blockAlignment => switch (this) {
    center => Alignment.center,
    left => Alignment.centerLeft,
    right => Alignment.centerRight,
  };

  /// 存档里存的是枚举名；认不出来（含空）就回落到居中
  static LyricAlignment parse(String? name) {
    for (final LyricAlignment value in values) {
      if (value.name == name) {
        return value;
      }
    }
    return center;
  }
}
