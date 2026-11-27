import 'package:flutter/material.dart';

import '../../theme/tokens.dart';

/// 分组小标题：设置、均衡器这类「一页分几组」的页面共用。
///
/// 之前设置页和均衡器各自算了一遍（一个 `labelLarge` + 主色、不缩进，一个
/// 同样的字但左右各缩 12），字号一样、间距不一样，放在同一屏里能看出错位。
/// 现在字号 / 颜色 / 上下留白都收在这里，需要跟卡片内容对齐时传 [indent]，
/// 右端要挂状态文字或按钮时传 [trailing]。
///
/// 颜色跟 [ColorScheme.primary] 同源，不取第三色（tertiary）：M3 的 tertiary
/// 是色相偏出去约 60° 的一组对比色，青绿主色下它会落到暖橙那一档（动态取色
/// 跟着封面走时尤其跳），分组标题压在卡片外面、字号又小，一暖一冷很刺眼。
/// 三组色相仍留给真正需要区分的地方（选中行、开关、播放键）。
class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key, this.indent = 0, this.trailing});

  final String text;

  /// 左右各缩进多少。分组的卡片自身有内边距时传卡片的水平内边距，
  /// 标题才和卡片里的正文左边缘对齐。
  final double indent;

  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Widget label = Text(
      text,
      style: theme.textTheme.labelLarge?.copyWith(
        color: theme.colorScheme.primary,
      ),
    );
    return Padding(
      padding: EdgeInsets.fromLTRB(indent, Spacing.md, indent, Spacing.xs),
      child: trailing == null
          ? label
          : Row(
              children: <Widget>[
                Expanded(child: label),
                trailing!,
              ],
            ),
    );
  }
}
