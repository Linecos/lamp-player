import 'dart:io' show File;
import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 封面编辑窗：左边看大图，右边改 / 恢复。
///
/// 艺术家、专辑、歌单三个入口共用。它们的差别只有两处——预览是圆形还是
/// 圆角方形、以及没有封面时的占位长什么样——其余交互完全一样，所以做成
/// 一个带参数的小窗，而不是三份各写一遍。
///
/// 尺寸策略：宽度最多 760、高度最多 440，并跟着窗口缩（留 48 的边）。
/// 左侧预览区**取可用空间的短边**做正方形，图片用 `BoxFit.cover` 铺满——
/// 这样竖图横图都不会变形，也不会出现「图片顶出对话框」。
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
    final double width = math.min(760, math.max(380, viewport.width - 48));
    final double height = math.min(440, math.max(320, viewport.height - 48));
    // 右侧动作区固定宽度：按钮文字是定的，跟着内容走反而每次字数变了就跳
    final double actionWidth = math.min(248, width * 0.36);

    return Dialog(
      clipBehavior: Clip.antiAlias,
      insetPadding: const EdgeInsets.all(24),
      child: SizedBox(
        width: width,
        height: height,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Expanded(child: _buildPreview(context)),
            SizedBox(
              width: actionWidth,
              child: _buildActions(context, theme, scheme),
            ),
          ],
        ),
      ),
    );
  }

  /// 左侧预览：取可用区域的短边做正方形，居中放。
  Widget _buildPreview(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          // 短边：宽比高窄时按宽，反之按高。两种极端下都不会溢出
          final double side = math.min(
            constraints.maxWidth,
            constraints.maxHeight,
          );
          if (!side.isFinite || side <= 0) {
            return const SizedBox.shrink();
          }
          return Center(child: _buildCover(side));
        },
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

  Widget _buildActions(
    BuildContext context,
    ThemeData theme,
    ColorScheme scheme,
  ) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 24, 20, 20),
      child: Column(
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
          const Spacer(),
          Text(
            '建议用正方形图片；过大的图会自动缩到 1024 长边。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
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
}
