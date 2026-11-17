import 'dart:io' show File;
import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 封面编辑窗：左上角看封面，右侧改 / 恢复。
///
/// 艺术家、专辑、歌单三个入口共用。它们的差别只有两处——预览是圆形还是
/// 圆角方形、以及没有封面时的占位长什么样——其余交互完全一样，所以做成
/// 一个带参数的小窗，而不是三份各写一遍。
///
/// 尺寸策略：窗口本身放到 880×540（跟随窗口缩，留 48 的边），但封面**不**
/// 跟着窗口一起变大——固定在 [_coverMaxSide] 以内，贴在左上角，右边留给
/// 选项。这样窗口变大只是让文字与按钮更松快，封面不会撑成一整面墙；图片
/// 用 `BoxFit.cover` 铺进正方形，竖图横图都不变形，也不会「顶出对话框」。
class CoverEditorDialog extends StatefulWidget {
  const CoverEditorDialog({
    super.key,
    required this.title,
    required this.kindLabel,
    required this.coverPath,
    required this.circular,
    required this.hasCustomCover,
    required this.onPick,
    required this.onReset,
    this.placeholderBuilder,
  });

  /// 目标名称（艺术家名 / 专辑名 / 歌单名）
  final String title;

  /// 类型标签，显示在标题上方的小字
  final String kindLabel;

  /// 当前封面（自定义或自动）；为空时显示占位
  final String? coverPath;

  /// 艺术家头像是圆的，专辑与歌单是圆角方形
  final bool circular;

  /// 当前是否有自定义封面：没有时「恢复默认」不可点
  final bool hasCustomCover;

  /// 「更换封面…」的实际动作：选图并写入，返回新的封面路径；用户取消返回 null
  final Future<String?> Function() onPick;

  /// 「恢复默认封面」的实际动作。
  ///
  /// 返回恢复之后的封面路径（可能为空，表示连自动封面都没有）——对话框
  /// 自己不知道「默认封面」是哪一张，得由调用方在重读覆盖表之后算出来，
  /// 否则撤掉自定义封面时预览会一直停在旧图上。
  final Future<String?> Function() onReset;

  /// 没有封面时显示的占位。
  ///
  /// 传的是 builder 而不是现成的 widget：占位本身要跟着预览区尺寸缩放
  /// （艺术家的首字母头像就是这么来的），尺寸只有对话框内部才知道。
  final Widget Function(double side)? placeholderBuilder;

  @override
  State<CoverEditorDialog> createState() => _CoverEditorDialogState();
}

class _CoverEditorDialogState extends State<CoverEditorDialog> {
  /// 封面的最大边长。
  ///
  /// 故意**不**跟着对话框一起涨：窗口放大是为了让右边的文字与按钮松快，
  /// 不是为了让预览变成整面墙。300 在 880 宽的窗里看着像个「缩略图」，
  /// 又足够看清一张封面有没有放错。
  static const double _coverMaxSide = 300;

  /// 封面四周的留白：左边与上边让它贴住左上角但不顶到边。
  static const EdgeInsets _previewPadding = EdgeInsets.fromLTRB(28, 28, 0, 28);

  /// 右侧选项区的内容最大宽度：窗口再宽也不再拉长按钮
  static const double _actionsMaxWidth = 380;

  late String? _path = widget.coverPath;
  late bool _hasCustom = widget.hasCustomCover;
  bool _busy = false;

  /// 换图计数：用户挑了同一张图时路径不变，`Image.file` 会认为没变化而
  /// 不重绘，加进 key 里强制重建一次
  int _revision = 0;

  Future<void> _pick() async {
    if (_busy) {
      return;
    }
    setState(() => _busy = true);
    try {
      final String? next = await widget.onPick();
      if (!mounted || next == null) {
        return;
      }
      setState(() {
        _path = next;
        _hasCustom = true;
        _revision += 1;
      });
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _reset() async {
    if (_busy || !_hasCustom) {
      return;
    }
    setState(() => _busy = true);
    try {
      final String? next = await widget.onReset();
      if (!mounted) {
        return;
      }
      setState(() {
        _path = next;
        _hasCustom = false;
        _revision += 1;
      });
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final Size viewport = MediaQuery.sizeOf(context);

    // 跟随窗口缩，但不小于一个还能看清按钮的下限
    final double width = math.min(880, math.max(420, viewport.width - 48));
    final double height = math.min(540, math.max(360, viewport.height - 48));

    // 封面边长：先按上限，再按可用高度收，最后限制在窗口宽度的 40% 以内——
    // 窗口小时优先牺牲封面，保证右侧两个按钮与提示语都还有地方放
    final double side = math.min(
      _coverMaxSide,
      math.min(height - _previewPadding.vertical, width * 0.40),
    );

    return Dialog(
      clipBehavior: Clip.antiAlias,
      insetPadding: const EdgeInsets.all(24),
      child: SizedBox(
        width: width,
        height: height,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  // 左：封面贴左上角，列宽只按封面本身撑开，多余空间留给右边
                  SizedBox(
                    width: side + _previewPadding.horizontal,
                    child: _buildPreview(side),
                  ),
                  // 右：选项
                  Expanded(child: _buildActions(theme, scheme)),
                ],
              ),
            ),
            // 页脚占满整窗宽：「关闭」才能真正落到右下角，提示语也才好居中
            _buildFooter(theme, scheme),
          ],
        ),
      ),
    );
  }

  /// 左侧预览：固定尺寸的封面贴在左上角，下面与右边留白。
  ///
  /// 以前是 `Center` + 取可用空间短边：窗口一大封面就跟着涨，而且垂直居中
  /// 会让它悬在半空。现在封面尺寸是算好的定值，位置固定左上。
  Widget _buildPreview(double side) {
    return Padding(
      padding: _previewPadding,
      child: Align(alignment: Alignment.topLeft, child: _buildCover(side)),
    );
  }

  /// 页脚：提示语居中，「关闭」贴右下角。
  ///
  /// 两行而不是一行（提示 + 按钮并排）：窗口缩到 420 宽时提示语会折成两三行，
  /// 和右侧按钮抢同一行的横向空间，挤起来就会互相压字。
  Widget _buildFooter(ThemeData theme, ColorScheme scheme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 0, 28, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            '建议用正方形图片；过大的图会自动缩到 1024 长边。',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 4),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('关闭'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCover(double side) {
    final String? path = _path;
    final bool hasPath = path != null && path.trim().isNotEmpty;

    final Widget content = hasPath
        ? Image.file(
            File(path),
            key: ValueKey<String>('cover-preview-$path-$_revision'),
            width: side,
            height: side,
            fit: BoxFit.cover,
            gaplessPlayback: true,
            errorBuilder: (BuildContext context, Object error, StackTrace? _) =>
                _buildPlaceholder(side),
          )
        : _buildPlaceholder(side);

    return widget.circular
        // 圆形一律 ClipOval：`ClipRRect(size/2)` 在非整数尺寸下会出现平边
        ? ClipOval(
            child: SizedBox.square(dimension: side, child: content),
          )
        : ClipRRect(
            // 圆角跟着尺寸走（约 6%），大图小图看起来是同一套圆角
            borderRadius: BorderRadius.circular(side * 0.06),
            child: SizedBox.square(dimension: side, child: content),
          );
  }

  Widget _buildPlaceholder(double side) {
    final Widget Function(double side)? custom = widget.placeholderBuilder;
    if (custom != null) {
      return SizedBox.square(dimension: side, child: custom(side));
    }
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Container(
      width: side,
      height: side,
      color: scheme.surfaceContainerHighest,
      alignment: Alignment.center,
      child: Icon(
        Icons.music_note_outlined,
        size: side * 0.32,
        color: scheme.onSurfaceVariant,
      ),
    );
  }

  Widget _buildActions(ThemeData theme, ColorScheme scheme) {
    // 靠左上对齐、宽度封顶：窗口放大后按钮不再被拉成一条长条
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 28, 28, 8),
      child: Align(
        alignment: Alignment.topLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: _actionsMaxWidth),
          child: _buildActionsColumn(theme, scheme),
        ),
      ),
    );
  }

  Widget _buildActionsColumn(ThemeData theme, ColorScheme scheme) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(
          widget.kindLabel,
          style: theme.textTheme.labelMedium?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          widget.title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 20),
        FilledButton.icon(
          onPressed: _busy ? null : _pick,
          icon: const Icon(Icons.image_outlined, size: 18),
          label: const Text('更换封面…'),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          // 没有自定义封面时无事可恢复，禁用比点了没反应更清楚
          onPressed: _busy || !_hasCustom ? null : _reset,
          icon: const Icon(Icons.restore, size: 18),
          label: const Text('恢复默认'),
        ),
        if (_hasCustom) ...<Widget>[
          const SizedBox(height: 10),
          Text(
            '当前使用的是自定义封面',
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );
  }
}
