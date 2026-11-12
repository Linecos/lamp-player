import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../alphabet_index.dart';

/// 字母导航条与卡片之间预留的宽度：导航条 + 与滚动条的间隙 + 一点呼吸位。
///
/// 「与滚轮保持距离」是硬要求：桌面端的滚动条贴在视口最右边，导航条贴着它
/// 会互相压住，鼠标划过时也不知道点到谁。所以导航条整体往左让 [railInset]，
/// 卡片再往左让出整条 [gridRightReserve]，谁都不重叠。
const double railWidth = 22;
const double railInset = 20;
const double gridRightReserve = railWidth + railInset + 12;

/// 每段标题占的高度（含上下空隙）
const double alphabetHeaderExtent = 34;

/// 按首字母分段、带右侧字母导航的网格。
///
/// 专辑与艺术家共用：两边只是卡片不同，分组、跳转、贴边规则完全一致。
class AlphabetGridView<T> extends StatefulWidget {
  const AlphabetGridView({
    super.key,
    required this.items,
    required this.labelOf,
    required this.itemBuilder,
    required this.maxCrossAxisExtent,
    required this.aspectRatio,
    this.storageKey,
    this.bottomPadding = 0,
    this.topPadding = 8,
    this.crossAxisSpacing = 16,
    this.mainAxisSpacing = 16,
    this.columnWidthHint,
  });

  final List<T> items;

  /// 分组 / 排序用的显示名（专辑名、艺术家名）
  final String Function(T item) labelOf;

  /// [index] 是**这一桶里**的序号，不是整列的序号 —— 拿它做 key 会跨段撞车，
  /// 需要稳定 key 时请用条目自己的标识。
  final Widget Function(BuildContext context, T item, int index) itemBuilder;

  final double maxCrossAxisExtent;
  final double aspectRatio;

  /// 滚动位置的存储键：切分区再切回来还停在原处
  final Key? storageKey;

  /// 底部留白（播放岛占的那一段）
  final double bottomPadding;
  final double topPadding;
  final double crossAxisSpacing;
  final double mainAxisSpacing;

  /// 算**列数**时该用的宽度（见 [AlphabetGridMetrics.columnWidth]）。
  ///
  /// 传的是「侧栏展开时」的内容区宽度——也就是这个窗口下最窄的那种布局。
  /// 这么定的原因：列数一旦随内容区宽度变，开关侧栏时就必然要重排列数，
  /// 而两套列数在同一个宽度下的卡片尺寸差 20% 左右，看上去就是封面
  /// 「先变大再变小」。把列数钉在窗口宽度上，开关侧栏只改变卡片大小
  /// （单调、连续），不再跳变。
  ///
  /// 空值时退回按当前宽度算（独立使用 / 测试）。
  final double? columnWidthHint;

  @override
  State<AlphabetGridView<T>> createState() => _AlphabetGridViewState<T>();
}

class _AlphabetGridViewState<T> extends State<AlphabetGridView<T>> {
  final ScrollController _controller = ScrollController();

  List<AlphabetBucket<T>>? _buckets;
  List<T>? _bucketsFor;

  /// 当前滚动位置落在哪一段，用来给导航条上的字母加重。
  ///
  /// 用 [ValueNotifier] 而不是 `setState`：跨段时只有导航条那几个字母要重画，
  /// 整棵网格（二十来个 `SliverGrid` 加它们的 delegate）没必要跟着重建。
  final ValueNotifier<String?> _active = ValueNotifier<String?>(null);

  /// 每段标题的滚动偏移：布局时算一次，滚动通知只查这张表。
  ///
  /// 以前是每个滚动通知都重建一遍 counts 列表、再对每一段重新累加
  /// （O(段数²)），滚动时白扔一堆计算。
  List<double> _sectionOffsets = const <double>[];

  /// 已经排了一次「按当前偏移补算加重项」的回调
  bool _syncScheduled = false;

  @override
  void dispose() {
    _controller.dispose();
    _active.dispose();
    super.dispose();
  }

  List<AlphabetBucket<T>> _grouped() {
    final List<AlphabetBucket<T>>? cached = _buckets;
    if (cached != null && identical(_bucketsFor, widget.items)) {
      return cached;
    }
    final List<AlphabetBucket<T>> buckets = groupByAlphabet<T>(
      widget.items,
      widget.labelOf,
    );
    _buckets = buckets;
    _bucketsFor = widget.items;
    return buckets;
  }

  void _jumpTo(int index) {
    if (!_controller.hasClients ||
        index < 0 ||
        index >= _sectionOffsets.length) {
      return;
    }
    final double target = _sectionOffsets[index].clamp(
      0.0,
      _controller.position.maxScrollExtent,
    );
    _controller.animateTo(
      target,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
    );
  }

  /// [pixels] 落在哪一段：最后一段起点不超过它的那一段。
  ///
  /// 顶部（滚动偏移小于第一段的 [AlphabetGridMetrics.topPadding]）算第一段：
  /// 以前这里会让循环一次都不进、返回 null，结果停在顶上时导航条没有任何加重项。
  String? _letterAt(double pixels) {
    final List<AlphabetBucket<T>>? buckets = _buckets;
    if (buckets == null || buckets.isEmpty || _sectionOffsets.isEmpty) {
      return null;
    }
    String current = buckets.first.letter;
    for (int i = 0; i < _sectionOffsets.length && i < buckets.length; i += 1) {
      if (pixels + 1 >= _sectionOffsets[i]) {
        current = buckets[i].letter;
      } else {
        break;
      }
    }
    return current;
  }

  /// 滚动时更新「当前段」：只在跨段时通知一次，逐帧滚动不做事
  bool _handleScroll(ScrollNotification notification) {
    if (_sectionOffsets.isEmpty) {
      return false;
    }
    _active.value = _letterAt(notification.metrics.pixels);
    return false;
  }

  /// 布局完按**当前偏移**补算一次加重项。
  ///
  /// 两种情况靠它：切分区回来时滚动位置由 PageStorage 恢复（不是从 0 开始），
  /// 以及窗口变宽变窄后段偏移全变了 —— 这时候没有滚动通知，导航条会一直没有
  /// 加重项，或者停在上一套几何算出来的字母上。
  void _scheduleActiveSync() {
    if (_syncScheduled) {
      return;
    }
    _syncScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _syncScheduled = false;
      if (!mounted || !_controller.hasClients || _sectionOffsets.isEmpty) {
        return;
      }
      _active.value = _letterAt(_controller.offset);
    });
  }

  @override
  Widget build(BuildContext context) {
    final double? columnWidthHint = widget.columnWidthHint;
    final List<AlphabetBucket<T>> buckets = _grouped();
    final List<String> letters = <String>[
      for (final AlphabetBucket<T> bucket in buckets) bucket.letter,
    ];

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final AlphabetGridMetrics metrics = AlphabetGridMetrics(
          // 卡片不许跑到导航条底下，横向先把它让出来
          viewportWidth: math.max(0, constraints.maxWidth - gridRightReserve),
          maxCrossAxisExtent: widget.maxCrossAxisExtent,
          crossAxisSpacing: widget.crossAxisSpacing,
          mainAxisSpacing: widget.mainAxisSpacing,
          aspectRatio: widget.aspectRatio,
          headerExtent: alphabetHeaderExtent,
          topPadding: widget.topPadding,
          // 0 是通知器的初始值（还没算出来）：当成「没给」，别真按 0 去算列数
          columnWidth: columnWidthHint == null || columnWidthHint <= 0
              ? null
              : columnWidthHint - gridRightReserve,
        );
        _sectionOffsets = metrics.sectionOffsets(<int>[
          for (final AlphabetBucket<T> bucket in buckets) bucket.length,
        ]);
        _scheduleActiveSync();

        return Stack(
          children: <Widget>[
            NotificationListener<ScrollNotification>(
              onNotification: _handleScroll,
              child: CustomScrollView(
                key: widget.storageKey,
                controller: _controller,
                slivers: <Widget>[
                  SliverPadding(
                    padding: EdgeInsets.only(top: widget.topPadding),
                  ),
                  for (int i = 0; i < buckets.length; i += 1) ...<Widget>[
                    SliverToBoxAdapter(
                      child: _SectionHeader(
                        key: ValueKey<String>(
                          'alphabet-header-${buckets[i].letter}',
                        ),
                        letter: buckets[i].letter,
                        count: buckets[i].length,
                      ),
                    ),
                    SliverPadding(
                      padding: const EdgeInsets.only(right: gridRightReserve),
                      sliver: SliverGrid(
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: metrics.crossAxisCount,
                          mainAxisSpacing: widget.mainAxisSpacing,
                          crossAxisSpacing: widget.crossAxisSpacing,
                          childAspectRatio: widget.aspectRatio,
                        ),
                        delegate: SliverChildBuilderDelegate((
                          BuildContext context,
                          int index,
                        ) {
                          final T item = buckets[i].items[index];
                          return widget.itemBuilder(context, item, index);
                        }, childCount: buckets[i].length),
                      ),
                    ),
                  ],
                  SliverPadding(
                    padding: EdgeInsets.only(bottom: widget.bottomPadding),
                  ),
                ],
              ),
            ),
            Positioned(
              top: widget.topPadding,
              bottom: widget.bottomPadding,
              right: railInset,
              width: railWidth,
              // 只有这根导航条关心「现在在哪一段」，让它单独订阅，
              // 跨段滚动就不会牵动上面那串 sliver
              child: ValueListenableBuilder<String?>(
                valueListenable: _active,
                builder: (BuildContext context, String? active, Widget? _) {
                  return AlphabetRail(
                    letters: letters,
                    active: active,
                    onSelect: (String letter) {
                      _jumpTo(letters.indexOf(letter));
                    },
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }
}

/// 分段标题：一个字母 + 这一段的条目数
class _SectionHeader extends StatelessWidget {
  const _SectionHeader({super.key, required this.letter, required this.count});

  final String letter;
  final int count;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return SizedBox(
      height: alphabetHeaderExtent,
      child: Align(
        alignment: Alignment.centerLeft,
        child: Padding(
          padding: const EdgeInsets.only(left: 2, bottom: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: <Widget>[
              Text(
                letter,
                style: theme.textTheme.titleSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '$count',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 最右侧的字母导航条：`A`…`Z` 再接 `#`，点了跳到对应段。
class AlphabetRail extends StatelessWidget {
  const AlphabetRail({
    super.key,
    required this.letters,
    required this.onSelect,
    this.active,
  });

  final List<String> letters;
  final ValueChanged<String> onSelect;

  /// 当前滚动位置所在的那一段，加重显示
  final String? active;

  @override
  Widget build(BuildContext context) {
    if (letters.isEmpty) {
      return const SizedBox.shrink();
    }
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        // 高度不够时按均分缩小，宁可字小一点也不能溢出
        final double rowHeight = math.min(
          18,
          constraints.maxHeight / letters.length,
        );
        return Material(
          type: MaterialType.transparency,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              for (final String letter in letters)
                _RailLetter(
                  letter: letter,
                  height: rowHeight,
                  active: letter == active,
                  onTap: () => onSelect(letter),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _RailLetter extends StatelessWidget {
  const _RailLetter({
    required this.letter,
    required this.height,
    required this.active,
    required this.onTap,
  });

  final String letter;
  final double height;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: height,
      width: railWidth,
      child: InkWell(
        key: ValueKey<String>('alphabet-rail-$letter'),
        onTap: onTap,
        borderRadius: BorderRadius.circular(height / 2),
        child: Center(
          child: Text(
            letter,
            style: TextStyle(
              // 字跟着行高走：窗口再矮也不会把字母挤出格子
              fontSize: math.min(11, height * 0.82),
              height: 1,
              fontWeight: active ? FontWeight.w700 : FontWeight.w500,
              color: active ? scheme.primary : scheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }
}
