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
/// 品牌图标、折叠按钮和导航图标始终共用 x=36 的中轴。
///
/// 宽度 / 条目高度 / 文字透明度全部交给隐式动画（`AnimatedContainer`、
/// `AnimatedOpacity`）：它们只更新 RenderObject，**不会每帧重建整列子树**。
/// 早期版本用 `AnimatedBuilder` 包住整列，每帧重建 7 个导航项，展开/收起
/// 时每帧要 20~30ms，肉眼可见地卡。
class LibraryRail extends StatefulWidget {
  const LibraryRail({
    super.key,
    required this.expanded,
    required this.section,
    required this.onSelect,
    required this.onToggle,
    this.onWindowDragStart,
    this.onWindowDoubleTap,
  });

  final bool expanded;
  final LibrarySection section;
  final ValueChanged<LibrarySection> onSelect;
  final VoidCallback onToggle;

  /// 品牌区拖动窗口；为空时保持纯展示
  final VoidCallback? onWindowDragStart;

  /// 品牌区双击最大化 / 还原
  final VoidCallback? onWindowDoubleTap;

  static const double expandedWidth = 220;
  static const double collapsedWidth = 72;
  static const Duration animationDuration = Duration(milliseconds: 180);

  @override
  State<LibraryRail> createState() => _LibraryRailState();
}

class _LibraryRailState extends State<LibraryRail> {
  /// 标签是否还挂在树上。
  ///
  /// 收起时保留到动画结束，好让文字跟着宽度一起淡出；动画走完再摘掉，
  /// 读屏与测试都不该在收起状态下找到「音乐」这类文字。展开时立刻挂回。
  late bool _showLabels = widget.expanded;

  @override
  void didUpdateWidget(covariant LibraryRail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.expanded == oldWidget.expanded) {
      return;
    }
    if (widget.expanded) {
      setState(() => _showLabels = true);
      return;
    }
    Future<void>.delayed(LibraryRail.animationDuration, () {
      if (mounted && !widget.expanded) {
        setState(() => _showLabels = false);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;

    return AnimatedContainer(
      duration: LibraryRail.animationDuration,
      curve: Curves.easeInOutCubic,
      width: widget.expanded
          ? LibraryRail.expandedWidth
          : LibraryRail.collapsedWidth,
      clipBehavior: Clip.hardEdge,
      decoration: BoxDecoration(color: scheme.surfaceContainer),
      // 边框用前景绘制，避免内容因边框内缩 1px，
      // 导致图标中轴比折叠按钮偏左。
      foregroundDecoration: BoxDecoration(
        border: Border(right: BorderSide(color: scheme.outlineVariant)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _RailBrand(
            expanded: widget.expanded,
            showLabel: _showLabels,
            onDragStart: widget.onWindowDragStart,
            onDoubleTap: widget.onWindowDoubleTap,
          ),
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
                  icon: Icon(widget.expanded ? Icons.menu_open : Icons.menu),
                ),
              ),
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              children: <Widget>[
                for (final LibrarySection item in LibrarySection.values)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 2),
                    child: _RailItem(
                      section: item,
                      expanded: widget.expanded,
                      showLabel: _showLabels,
                      selected: item == widget.section,
                      onTap: () => widget.onSelect(item),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 侧栏顶部的品牌区：占位应用图标 + 应用名，高度与窗口标题条一致。
class _RailBrand extends StatelessWidget {
  const _RailBrand({
    required this.expanded,
    required this.showLabel,
    this.onDragStart,
    this.onDoubleTap,
  });

  final bool expanded;
  final bool showLabel;
  final VoidCallback? onDragStart;
  final VoidCallback? onDoubleTap;

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

    final Widget brandRow = SizedBox(
      height: LampTitleBar.height,
      child: Padding(
        padding: const EdgeInsets.only(left: 12, right: 12),
        // 与导航项同理：内容按固有宽度排，宽度动画中途由外层裁剪
        child: ClipRect(
          child: OverflowBox(
            alignment: Alignment.centerLeft,
            minWidth: 0,
            maxWidth: LibraryRail.expandedWidth,
            minHeight: 0,
            maxHeight: LampTitleBar.height,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                // 固定 48 宽，图标中轴与折叠按钮 / 导航图标一样落在 x=36。
                SizedBox(
                  width: 48,
                  height: LampTitleBar.height,
                  child: Center(child: mark),
                ),
                if (showLabel) ...<Widget>[
                  const SizedBox(width: 8),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 140),
                    child: AnimatedOpacity(
                      opacity: expanded ? 1 : 0,
                      duration: LibraryRail.animationDuration,
                      curve: Curves.easeInOutCubic,
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
                ],
              ],
            ),
          ),
        ),
      ),
    );

    final Widget brand = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onPanStart: onDragStart == null ? null : (_) => onDragStart!(),
      onDoubleTap: onDoubleTap,
      child: brandRow,
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
    required this.expanded,
    required this.showLabel,
    required this.selected,
    required this.onTap,
  });

  final LibrarySection section;
  final bool expanded;
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

    final Widget item = Material(
      color: selected ? scheme.secondaryContainer : Colors.transparent,
      borderRadius: BorderRadius.circular(28),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        hoverColor: scheme.onSurface.withValues(alpha: 0.08),
        child: AnimatedContainer(
          duration: LibraryRail.animationDuration,
          curve: Curves.easeInOutCubic,
          height: expanded ? 56 : 48,
          // 左侧固定 12：图标在展开 / 收起两种状态下都停在 x=24，
          // 右侧内边距随收起淡出，给文字让出空间。
          padding: EdgeInsets.only(left: 12, right: expanded ? 12 : 0),
          // 内容按固有宽度布局、交给外层裁剪：动画中途容器比文字窄时，
          // 若让 Row 去挤，Text 在极窄约束下会撑破布局并触发溢出断言。
          // 用 OverflowBox 而不是 UnconstrainedBox：后者会自己报溢出。
          child: ClipRect(
            child: OverflowBox(
              alignment: Alignment.centerLeft,
              minWidth: 0,
              maxWidth: LibraryRail.expandedWidth,
              minHeight: 0,
              maxHeight: expanded ? 56 : 48,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Icon(
                    selected ? section.selectedIcon : section.icon,
                    size: 24,
                    color: foreground,
                  ),
                  if (showLabel) ...<Widget>[
                    const SizedBox(width: 8),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 164),
                      child: AnimatedOpacity(
                        opacity: expanded ? 1 : 0,
                        duration: LibraryRail.animationDuration,
                        curve: Curves.easeInOutCubic,
                        child: Text(
                          section.label,
                          maxLines: 1,
                          overflow: TextOverflow.clip,
                          style: theme.textTheme.labelLarge?.copyWith(
                            color: foreground,
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
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
      child: expanded ? item : Tooltip(message: section.label, child: item),
    );
  }
}
