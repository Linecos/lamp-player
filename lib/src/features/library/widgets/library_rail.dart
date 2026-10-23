import 'package:flutter/material.dart';

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
/// 展开 220dp：图标与文字横向排列；折叠 72dp：只留图标，
/// 这样折叠按钮与下方图标共用同一条中轴。
class LibraryRail extends StatelessWidget {
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

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOutCubic,
      width: expanded ? expandedWidth : collapsedWidth,
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
            SizedBox(
              height: 64,
              child: Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.only(left: 12, top: 8),
                  child: IconButton(
                    onPressed: onToggle,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints.tightFor(
                      width: 48,
                      height: 48,
                    ),
                    iconSize: 24,
                    tooltip: expanded ? '收起导航栏' : '展开导航栏',
                    icon: Icon(expanded ? Icons.menu_open : Icons.menu),
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
                        expanded: expanded,
                        selected: item == section,
                        onTap: () => onSelect(item),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RailItem extends StatelessWidget {
  const _RailItem({
    required this.section,
    required this.expanded,
    required this.selected,
    required this.onTap,
  });

  final LibrarySection section;
  final bool expanded;
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
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            // 展开动画进行到一半时宽度还不够放图标 + 文字，
            // 先保持图标居中，等宽度够了再显示文字，避免溢出。
            final bool showLabel = expanded && constraints.maxWidth >= 56;
            return SizedBox(
              height: expanded ? 56 : 48,
              child: showLabel
                  ? Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Row(
                        children: <Widget>[
                          iconWidget,
                          const SizedBox(width: 8),
                          Flexible(child: label),
                        ],
                      ),
                    )
                  : Center(child: iconWidget),
            );
          },
        ),
      ),
    );

    return Semantics(
      button: true,
      selected: selected,
      label: section.label,
      // 收起后只剩图标，用悬停提示补足名称。
      child: expanded ? item : Tooltip(message: section.label, child: item),
    );
  }
}
