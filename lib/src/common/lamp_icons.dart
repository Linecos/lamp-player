// 项目自带的小图标字体，由 assets/icons 下的 SVG 生成，不要手改。
//
// 生成命令（改了 SVG 之后重跑）：
//   dart pub global activate icon_font_generator
//   dart pub global run icon_font_generator:generator assets/icons \
//       assets/fonts/lamp_icons.ttf \
//       --output-class-file=lib/src/common/lamp_icons.dart \
//       --class-name=LampIcons --font-name=LampIcons
//
// 只收「内置图标集（`Icons`）里没有合适字形」的那几个：唱片、四柱、笔刷、
// 店铺、GitHub 标记。有现成图形的照旧走 `Icons`（放大镜、排序箭头）；窗口四键是自绘
// （15px 下要更细的笔画与描影，见 `lib/src/app/title_bar.dart`）。字体越大，
// Release 的图标子集裁剪越容易漏，别把已有的图标往里搬。
//
// 来源与许可（均为 Apache License 2.0）：
// - album_outlined / album_filled / bar_chart_4_bars：Material Symbols
//   （google/material-design-icons）
// - brush_variant / github / store_filled / store_outline：Material Design Icons
//   （Templarian/MaterialDesign）
//
// 生成后按文件名排序占 0xe000 起的私有区码位，新增图标会改已有码位——只认
// 下面的常量名，不要在任何地方写死码位数字。
//
// 改 SVG 时每条子路径都要显式写 `Z`：生成器遇到新的 `M` 不会闭合上一条子
// 路径，而是把它连成一条线（画面上就是一根多出来的斜线）。

import 'package:flutter/widgets.dart';

/// 自带图标字体里的字形，用法与 `Icons` 相同：`Icon(LampIcons.albumFilled)`。
class LampIcons {
  const LampIcons._();

  /// 字体族名，与 pubspec.yaml 的 `fonts:` 段一致
  static const String iconFontFamily = 'LampIcons';

  /// 唱片（实心）：侧栏「专辑」选中态
  static const IconData albumFilled = IconData(
    0xe000,
    fontFamily: iconFontFamily,
  );

  /// 唱片（空心）：侧栏「专辑」未选中态
  static const IconData albumOutlined = IconData(
    0xe001,
    fontFamily: iconFontFamily,
  );

  /// 四柱柱状图（带基线）：音乐库「听歌统计」入口
  static const IconData barChart4Bars = IconData(
    0xe002,
    fontFamily: iconFontFamily,
  );

  /// 宽头画笔：设置页「配色」行
  static const IconData brushVariant = IconData(
    0xe003,
    fontFamily: iconFontFamily,
  );

  /// GitHub 标记：设置「关于」里的仓库入口
  static const IconData github = IconData(0xe004, fontFamily: iconFontFamily);

  /// 店铺（实心）：侧栏「音乐库」选中态
  static const IconData storeFilled = IconData(
    0xe005,
    fontFamily: iconFontFamily,
  );

  /// 店铺（空心）：侧栏「音乐库」未选中态
  static const IconData storeOutline = IconData(
    0xe006,
    fontFamily: iconFontFamily,
  );
}
