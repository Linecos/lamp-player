import 'package:flutter/material.dart';

/// 主界面左侧导航分区。
///
/// 与设计稿保持一致，共八个入口。
///
/// 八个分区都已接入真实数据：歌单 / 收藏 / 历史走 `api::collections`（契约 v0.3），
/// 艺术家 / 专辑由曲库聚合得到，音乐库管目录与扫描，设置页含主题切换与输出配置。
enum LibrarySection {
  // 未选中用线性图标、选中用实心图标：八个分区保持同一套状态语言。
  // 「歌单」「历史」原先两种状态是同一个字形，点击后只剩底色变化，看不出来。
  music('音乐', Icons.music_note_outlined, Icons.music_note),
  playlists('歌单', Icons.playlist_play_outlined, Icons.playlist_play),
  history('历史', Icons.access_time, Icons.access_time_filled),
  favorites('收藏', Icons.favorite_outline, Icons.favorite),
  artists('艺术家', Icons.person_outline, Icons.person),
  albums('专辑', Icons.library_books_outlined, Icons.library_books),

  // 店铺门面（mdi:store 的 Material 同名字形）
  library('音乐库', Icons.storefront_outlined, Icons.storefront),

  settings('设置', Icons.settings_outlined, Icons.settings);

  const LibrarySection(this.label, this.icon, this.selectedIcon);

  final String label;
  final IconData icon;
  final IconData selectedIcon;
}

/// 可展开 / 折叠的侧边导航栏，画成一块浮在底色上的圆角卡片（岛）。
///
/// 展开 220dp、折叠 72dp。应用图标与名称不在这里——它们在顶部通栏条里
/// （见 `library_page` 的顶栏），侧栏从折叠按钮开始。
///
/// 宽度 / 条目高度 / 文字透明度全部交给隐式动画（`AnimatedContainer`、
/// `AnimatedOpacity`）：它们只更新 RenderObject，**不会每帧重建整列子树**。
/// 早期版本用 `AnimatedBuilder` 包住整列，每帧重建 7 个导航项，展开/收起
/// 时每帧要 20~30ms，肉眼可见地卡。
class LibraryRail extends StatefulWidget {
  /// 侧栏当前是展开还是收起。
  ///
  /// 曲库页持有真实状态，这里只做**镜像**：给曲库页之外的浮层（AppToast 之类）
  /// 用——它们不知道曲库页，但需要知道「主内容区从哪里开始」才能把自己
  /// 水平居中到主区域而不是整个窗口。
  static final ValueNotifier<bool> expandedNotifier = ValueNotifier<bool>(true);

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
  static const Duration animationDuration = Duration(milliseconds: 180);

  /// 岛与窗口边缘、岛与岛之间留的间隙
  static const double islandGap = 12;

  /// 岛卡片的圆角
  static const double islandRadius = 18;

  /// 主内容区的左边界：侧栏宽度 + 两侧间隙。
  ///
  /// 浮层（`AppToast` 之类）要水平居中到内容区时用它，而不是侧栏宽度本身。
  static double contentLeftInset(bool expanded) =>
      islandGap * 2 + (expanded ? expandedWidth : collapsedWidth);

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

    // 宽度交给隐式动画；**颜色不能也放在这里**。
    //
    // MaterialApp 切深浅色时 `AnimatedTheme` 已经在 200ms 内逐帧插值，如果
    // 这层 `AnimatedContainer` 再对底色做一次 180ms 动画，就是「追一个每帧
    // 都在移动的目标」——实际要将近两倍时长才到位，观感是内容区变完了、
    // 侧栏还在慢慢追。底色改成静态 `Container`，直接跟着主题插值走。
    //
    // 圆角由外层 `ClipRRect` 负责：宽度动画期间每帧都会重裁一次，
    // 边缘不会先出现直角、动画结束才补圆角。
    return ClipRRect(
      borderRadius: BorderRadius.circular(LibraryRail.islandRadius),
      child: AnimatedContainer(
        duration: LibraryRail.animationDuration,
        curve: Curves.easeInOutCubic,
        width: widget.expanded
            ? LibraryRail.expandedWidth
            : LibraryRail.collapsedWidth,
        child: Container(
          key: const ValueKey<String>('rail-surface'),
          decoration: BoxDecoration(
            color: scheme.surfaceContainer,
            borderRadius: BorderRadius.circular(LibraryRail.islandRadius),
          ),
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
                      onPressed: widget.onToggle,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints.tightFor(
                        width: 48,
                        height: 48,
                      ),
                      iconSize: 24,
                      tooltip: widget.expanded ? '收起导航栏' : '展开导航栏',
                      icon: Icon(
                        widget.expanded ? Icons.menu_open : Icons.menu,
                      ),
                    ),
                  ),
                ),
              ),
              Expanded(
                // 左右内边距固定 8、条目自己的左内边距固定 16，两者相加 24 与图标
                // 的原始左边距完全一致 —— 展开时 220-16=204 宽，收起时 72-16=56 宽，
                // 图标都停在 x=36。这里不留任何动画：两个隐式动画各自起跑，
                // 中途会把图标带偏几像素（试过，会漂 4px）。
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  child: ListView(
                    padding: EdgeInsets.zero,
                    children: <Widget>[
                      for (final LibrarySection item in LibrarySection.values)
                        // 间距固定：条目位置在整段动画里不动，才不会抖
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
              ),
            ],
          ),
        ),
      ),
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

    // 占位高度固定 56、背景（胶囊）只在里面垂直居中：
    // · 位置不动 → 收起过程中七个条目不会上下挪（那就是「抖」）
    // · 背景可以矮下来 → 收起时 48×48 是正圆，展开时才是 56 高的扁胶囊。
    //   若让背景撑满整个占位高度，折叠宽度下会变成 48×56 的竖椭圆。
    final Widget item = SizedBox(
      height: 56,
      child: Center(
        // Center 给的是松约束，这里摊开撑满可用宽，否则 Material 会缩到
        // OverflowBox 的固有宽度（220）而溢出条目
        child: SizedBox(
          width: double.infinity,
          child: Material(
            key: ValueKey<String>('rail-capsule-${section.name}'),
            color: selected ? scheme.secondaryContainer : Colors.transparent,
            shape: const StadiumBorder(),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: onTap,
              hoverColor: scheme.onSurface.withValues(alpha: 0.08),
              child: Container(
                // 高度两态一致：展开 56 高的胶囊、收起 56×56 的正圆，
                // 两端半圆半径都是 28，形状才对得上。左内边距 16 与外面
                // 那层 8 相加是 24，图标始终停在 x=36，这一层不需要动画
                height: 56,
                padding: const EdgeInsets.only(left: 16, right: 12),
                // 内容按固有宽度布局、交给外层裁剪：动画中途容器比文字窄时，
                // 若让 Row 去挤，Text 在极窄约束下会撑破布局并触发溢出断言。
                // 用 OverflowBox 而不是 UnconstrainedBox：后者会自己报溢出。
                child: ClipRect(
                  child: OverflowBox(
                    alignment: Alignment.centerLeft,
                    minWidth: 0,
                    maxWidth: LibraryRail.expandedWidth,
                    minHeight: 0,
                    maxHeight: 56,
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
