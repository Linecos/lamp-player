import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';

import '../../../app/title_bar.dart';

/// 主界面左侧导航分区。
///
/// 与设计稿保持一致，共七个入口。
///
/// 七个分区都已接入真实数据：歌单 / 收藏 / 历史走 `api::collections`（契约 v0.3），
/// 艺术家 / 专辑由曲库聚合得到，设置页含主题切换与扫描结果展示。
enum LibrarySection {
  music('音乐', Icons.music_note_outlined, Icons.music_note),
  playlists('歌单', Icons.format_list_bulleted, Icons.format_list_bulleted),
  history('历史', Icons.schedule_outlined, Icons.schedule),
  favorites('收藏', Icons.favorite_outline, Icons.favorite),
  artists('艺术家', Icons.person_outline, Icons.person),
  albums('专辑', Icons.library_books_outlined, Icons.library_books),
  settings('设置', Icons.settings_outlined, Icons.settings);

  const LibrarySection(this.label, this.icon, this.selectedIcon);

  final String label;
  final IconData icon;
  final IconData selectedIcon;
}

/// 可展开 / 折叠的侧边导航栏。
///
/// 展开 220dp：顶部显示占位应用图标 + 应用名，下面图标与文字横向排列；
/// 折叠 72dp：只留图标。侧栏一直贴到窗口顶部，把标题条区域的品牌包住。
/// 宽度、条目高度、文字透明度由同一个动画控制器驱动，
/// 品牌图标、折叠按钮和导航图标始终共用 x=36 的中轴。
class LibraryRail extends StatefulWidget {
  const LibraryRail({
    super.key,
    required this.expanded,
    required this.section,
    required this.onSelect,
    required this.onToggle,
  });

  final bool expanded;
  final LibrarySection section;
  final ValueChanged<LibrarySection> onSelect;
  final VoidCallback onToggle;

  static const double expandedWidth = 220;
  static const double collapsedWidth = 72;
  static const Duration animationDuration = Duration(milliseconds: 240);

  @override
  State<LibraryRail> createState() => _LibraryRailState();
}

class _LibraryRailState extends State<LibraryRail>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: LibraryRail.animationDuration,
    value: widget.expanded ? 0 : 1,
  );

  @override
  void didUpdateWidget(covariant LibraryRail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.expanded == oldWidget.expanded) {
      return;
    }
    // 0 表示展开，1 表示收起；统一用一条进度算宽度和文字透明度。
    if (widget.expanded) {
      _controller.reverse();
    } else {
      _controller.forward();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;

    return AnimatedBuilder(
      animation: _controller,
      builder: (BuildContext context, Widget? child) {
        final double progress = Curves.easeInOutCubic.transform(
          _controller.value,
        );
        final double width = lerpDouble(
          LibraryRail.expandedWidth,
          LibraryRail.collapsedWidth,
          progress,
        )!;
        // 文字比宽度更早淡出；完全收起后从树里移除，读屏和测试都不会再找到它。
        final double labelOpacity = (1 - progress * 1.6).clamp(0.0, 1.0);
        final bool showLabel = labelOpacity > 0.01;

        return Container(
          width: width,
          decoration: BoxDecoration(color: scheme.surfaceContainer),
          // 边框用前景绘制，避免 Container 因边框内缩 1px，
          // 导致收起时图标中轴比折叠按钮偏左。
          foregroundDecoration: BoxDecoration(
            border: Border(right: BorderSide(color: scheme.outlineVariant)),
          ),
          child: ClipRect(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                _RailBrand(labelOpacity: labelOpacity, showLabel: showLabel),
                SizedBox(
                  height: 64,
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Padding(
                      padding: const EdgeInsets.only(left: 12, top: 8),
                      child: IconButton(
                        onPressed: widget.onToggle,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints.tightFor(
                          width: 48,
                          height: 48,
                        ),
                        iconSize: 24,
                        tooltip: widget.expanded ? '收起导航栏' : '展开导航栏',
                        icon: AnimatedSwitcher(
                          duration: const Duration(milliseconds: 160),
                          transitionBuilder:
                              (Widget child, Animation<double> animation) {
                                return FadeTransition(
                                  opacity: animation,
                                  child: ScaleTransition(
                                    scale: Tween<double>(
                                      begin: 0.8,
                                      end: 1,
                                    ).animate(animation),
                                    child: child,
                                  ),
                                );
                              },
                          child: Icon(
                            widget.expanded ? Icons.menu_open : Icons.menu,
                            key: ValueKey<bool>(widget.expanded),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 4,
                    ),
                    children: <Widget>[
                      for (final LibrarySection item in LibrarySection.values)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 2),
                          child: _RailItem(
                            section: item,
                            progress: progress,
                            labelOpacity: labelOpacity,
                            showLabel: showLabel,
                            selected: item == widget.section,
                            onTap: () => widget.onSelect(item),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// 侧栏顶部的品牌区：占位应用图标 + 应用名，高度与窗口标题条一致。
class _RailBrand extends StatelessWidget {
  const _RailBrand({required this.labelOpacity, required this.showLabel});

  final double labelOpacity;
  final bool showLabel;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;

    // 占位图标：正式应用图标设计好后替换这一块。
    final Widget mark = Container(
      key: const ValueKey<String>('rail-brand-mark'),
      width: 28,
      height: 28,
      decoration: BoxDecoration(
        color: scheme.primaryContainer,
        borderRadius: BorderRadius.circular(9),
      ),
      child: Icon(Icons.lightbulb, size: 17, color: scheme.onPrimaryContainer),
    );

    final Widget brand = SizedBox(
      height: LampTitleBar.height,
      child: Padding(
        padding: const EdgeInsets.only(left: 12, right: 12),
        child: Row(
          children: <Widget>[
            // 固定 48 宽，图标中轴与折叠按钮 / 导航图标一样落在 x=36。
            SizedBox(
              width: 48,
              height: LampTitleBar.height,
              child: Center(child: mark),
            ),
            if (showLabel) ...<Widget>[
              const SizedBox(width: 8),
              Flexible(
                child: ClipRect(
                  child: Opacity(
                    opacity: labelOpacity,
                    child: Text(
                      'Lamp Player',
                      maxLines: 1,
                      overflow: TextOverflow.clip,
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: scheme.onSurface,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.2,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );

    return Semantics(
      container: true,
      label: 'Lamp Player',
      child: ExcludeSemantics(child: brand),
    );
  }
}

class _RailItem extends StatelessWidget {
  const _RailItem({
    required this.section,
    required this.progress,
    required this.labelOpacity,
    required this.showLabel,
    required this.selected,
    required this.onTap,
  });

  final LibrarySection section;
  final double progress;
  final double labelOpacity;
  final bool showLabel;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final Color foreground = selected
        ? scheme.onSecondaryContainer
        : scheme.onSurfaceVariant;

    final Widget iconWidget = Icon(
      selected ? section.selectedIcon : section.icon,
      size: 24,
      color: foreground,
    );
    final Widget label = Text(
      section.label,
      maxLines: 1,
      overflow: TextOverflow.clip,
      style: theme.textTheme.labelLarge?.copyWith(color: foreground),
    );

    final Widget item = Material(
      color: selected ? scheme.secondaryContainer : Colors.transparent,
      borderRadius: BorderRadius.circular(28),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        hoverColor: scheme.onSurface.withValues(alpha: 0.08),
        child: SizedBox(
          height: lerpDouble(56, 48, progress),
          child: Padding(
            // 左侧固定 12：图标在展开 / 收起两种状态下都停在 x=24，
            // 右侧内边距随收起淡出，给文字让出空间。
            padding: EdgeInsets.only(left: 12, right: 12 * (1 - progress)),
            child: Row(
              children: <Widget>[
                iconWidget,
                if (showLabel) ...<Widget>[
                  const SizedBox(width: 8),
                  Flexible(
                    child: ClipRect(
                      child: Opacity(opacity: labelOpacity, child: label),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );

    return Semantics(
      button: true,
      selected: selected,
      label: section.label,
      // 完全收起后只剩图标，用悬停提示补足名称。
      child: progress >= 1
          ? Tooltip(message: section.label, child: item)
          : item,
    );
  }
}
