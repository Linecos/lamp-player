import 'dart:io' show File;
import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 封面编辑窗：封面在左，右边是说明与两个动作。
///
/// 艺术家、专辑、歌单三个入口共用。它们的差别只有两处——预览是圆形还是
/// 圆角方形、以及没有封面时的占位长什么样——其余交互完全一样，所以做成
/// 一个带参数的小窗，而不是三份各写一遍。
///
/// 版式按内容收缩（`maxWidth` 封顶 520，高度自适应），不要「固定大窗 + 元素
/// 贴左上」：那样窗口一大，中间和右下全是空的，看着像没排完版。宽度窄到
/// 放不下并排时改成上下堆叠。
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
  /// 封面的目标边长。再大就喧宾夺主，再小看不清有没有放错图
  static const double _coverSide = 180;

  /// 并排时右侧动作区的宽度：按钮就按这个宽，不再拉成长条
  static const double _actionsWidth = 200;

  /// 窗口窄到这个宽度以下就上下堆叠
  static const double _stackBelow = 400;

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

    final double width = math.min(520, math.max(280, viewport.width - 48));
    final bool stacked = width < _stackBelow;
    // 并排时给右侧留够动作区，封面小一点也比把按钮挤成一条强
    final double side = stacked
        ? math.min(_coverSide, width - 48)
        : math.min(_coverSide, width - 48 - 20 - _actionsWidth);

    final Widget cover = _buildCover(side);
    final Widget actions = _buildActions(theme, scheme);

    return Dialog(
      clipBehavior: Clip.antiAlias,
      insetPadding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: width),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 16, 12, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              // 标题与右上角那个叉：和播放队列 / 均衡器 / 睡眠定时等弹窗
              // 一个样式，底部不再挂一枚「关闭」按钮
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
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
                      ],
                    ),
                  ),
                  IconButton(
                    key: const ValueKey<String>('cover-editor-close'),
                    tooltip: '关闭',
                    visualDensity: VisualDensity.compact,
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close, size: 20),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              if (stacked) ...<Widget>[
                Center(child: cover),
                const SizedBox(height: 16),
                actions,
              ] else
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    cover,
                    const SizedBox(width: 20),
                    Expanded(child: actions),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// 右侧动作区：说明 + 两个等宽按钮 + 当前状态。
  ///
  /// 整块宽度封顶在 [_actionsWidth] 并**在右侧剩余空间里居中**：按钮跟着
  /// 列宽拉伸会变成两条横贯的长条，而贴着左边排又会在右侧留下一条说不清
  /// 用途的空白——居中后两条毛病都没有。说明文字也在这一块里，左边缘与
  /// 按钮对齐，不会出现三种不同的起点。
  Widget _buildActions(ThemeData theme, ColorScheme scheme) {
    return Align(
      alignment: Alignment.topCenter,
      child: SizedBox(
        width: _actionsWidth,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              '建议用正方形图片；过大的图会自动缩到 1024 长边。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
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
              const SizedBox(height: 12),
              Text(
                '当前使用的是自定义封面',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
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
}
