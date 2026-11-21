import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../common/scroll/smooth_scroll.dart';
import '../alphabet_index.dart';
import 'library_rail.dart';

/// 从窗口边缘到网格可用宽度的固定损耗：侧栏与内容卡的间隙、内容卡的左右
/// 内边距、滚动条的呼吸位。侧栏宽度另算（见 [LibraryRail.expandedWidth]）。
const double _windowChrome = 68;

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

/// 网格左侧内缩。
///
/// 列表行的悬停胶囊在内容卡 16 的基础上再缩 10（给圆角留边），首列落在 26。
/// 网格原先贴着内容卡边缘从 16 起，切「音乐 ↔ 专辑」时整块内容横跳 10px。
/// 这里补同样的 10，两条左边缘才对得上。
const double alphabetGridLeftInset = 10;

/// 视口顶部那一条的位置：哪一段、段内第几条、以及在那一行里已经滚过去了多少。
///
/// 只记「像素偏移」是不够的：开关侧栏时列数不变但卡片会变宽，行高跟着变，
/// 同一个像素在新布局里指向的是另一条，而且越往下累计误差越大。存下条目本身的
/// 位置，几何一变就能把同一条重新放回视口顶部。
@immutable
class AlphabetScrollAnchor {
  const AlphabetScrollAnchor(this.section, this.item, this.fraction);

  final int section;
  final int item;
  final double fraction;
}

/// [pixels] 处视口顶部是哪一条（[AlphabetGridMetrics] 的几何是均匀的，
/// 段内按行折算即可）。
///
/// 返回 `null` 表示还没有可用的几何信息。
@visibleForTesting
AlphabetScrollAnchor? alphabetAnchorAt(
  AlphabetGridMetrics metrics,
  List<double> sectionOffsets,
  List<int> counts,
  double pixels,
) {
  if (sectionOffsets.isEmpty || counts.isEmpty) {
    return null;
  }
  int section = 0;
  for (int i = 0; i < sectionOffsets.length && i < counts.length; i += 1) {
    if (pixels + 0.5 >= sectionOffsets[i]) {
      section = i;
    } else {
      break;
    }
  }
  final double rowExtent =
      metrics.childMainAxisExtent + metrics.mainAxisSpacing;
  final double into = pixels - (sectionOffsets[section] + metrics.headerExtent);
  if (into <= 0 || rowExtent <= 0) {
    // 还停在段标题（甚至更上面）：记成第一行的「负偏移」，换算回去才是原位置。
    // 直接填 0 的话顶部 40 来个像素会被吃掉，收起侧栏时列表会往下跳一格
    return AlphabetScrollAnchor(section, 0, into <= 0 ? into : 0);
  }
  final int row = into ~/ rowExtent;
  final int count = counts[section];
  // 只记「这一行的第一条」：横向位置不在滚动偏移里，同一行里是哪一列无从得知，
  // 而恢复时只要保证同一条还在顶上就够了
  final int item = math.min(
    row * metrics.crossAxisCount,
    math.max(0, count - 1),
  );
  return AlphabetScrollAnchor(section, item, into - row * rowExtent);
}

/// 把锚点换算成新几何下的滚动偏移。
@visibleForTesting
double alphabetOffsetOf(
  AlphabetGridMetrics metrics,
  List<double> sectionOffsets,
  AlphabetScrollAnchor anchor,
) {
  if (sectionOffsets.isEmpty) {
    return 0;
  }
  final int section = anchor.section.clamp(0, sectionOffsets.length - 1);
  final double rowExtent =
      metrics.childMainAxisExtent + metrics.mainAxisSpacing;
  final int row = metrics.crossAxisCount <= 0
      ? 0
      : anchor.item ~/ metrics.crossAxisCount;
  // 行变矮之后原来的行内偏移可能超出一行，夹回一行之内；
  // 负值（停在段标题上方）是合法的，不夹
  final double fraction = math.min(anchor.fraction, math.max(0.0, rowExtent));
  return sectionOffsets[section] +
      metrics.headerExtent +
      row * rowExtent +
      fraction;
}

/// 按首字母分段、带右侧字母导航的网格。
///
/// 专辑与艺术家共用：两边只是卡片不同，分组、跳转、贴边规则完全一致。
class AlphabetGridView<T> extends StatefulWidget {
  const AlphabetGridView({
    super.key,
    required this.items,
    required this.labelOf,
    required this.itemBuilder,
    required this.tileWidth,
    required this.tileHeight,
    this.storageKey,
    this.bottomPadding = 0,
    this.topPadding = 8,
    this.crossAxisSpacing = 16,
    this.mainAxisSpacing = 16,
  });

  final List<T> items;

  /// 分组 / 排序用的显示名（专辑名、艺术家名）
  final String Function(T item) labelOf;

  /// [index] 是**这一桶里**的序号，不是整列的序号 —— 拿它做 key 会跨段撞车，
  /// 需要稳定 key 时请用条目自己的标识。
  final Widget Function(BuildContext context, T item, int index) itemBuilder;

  /// 卡片宽度上限：窗口变宽只加列数，列宽把剩余空间均分（所以可能比它略窄）。
  /// 卡片高度固定（见 [tileHeight]），切窗口化 / 全屏时视觉尺寸不变。
  final double tileWidth;
  final double tileHeight;

  /// 滚动位置的存储键：切分区再切回来还停在原处
  final Key? storageKey;

  /// 底部留白（播放岛占的那一段）
  final double bottomPadding;
  final double topPadding;
  final double crossAxisSpacing;
  final double mainAxisSpacing;

  @override
  State<AlphabetGridView<T>> createState() => _AlphabetGridViewState<T>();
}

/// 能在**布局阶段**修正滚动像素的控制器。
///
/// 侧栏展开 / 收起是个 220ms 的宽度动画，内容区每帧都在变宽变窄，行高跟着变，
/// 同一个像素每帧都指向别的位置。要是等这一帧画完再 `jumpTo` 去修，屏幕上就会
/// 先出现一帧错位、下一帧再跳回来——每帧一次，看起来是「卡片快速上下浮动」。
/// 这里把修正放到 [ScrollPosition.applyContentDimensions]：布局刚知道新的滚动
/// 范围、还没落笔，直接改 `pixels`，这一帧画出来的就是修正后的位置。
class _AnchorScrollController extends SmoothScrollController {
  /// 下一次布局要落到的像素（build 阶段按新几何算好），用掉即清
  double? pendingPixels;

  @override
  ScrollPosition createScrollPosition(
    ScrollPhysics physics,
    ScrollContext context,
    ScrollPosition? oldPosition,
  ) {
    return _AnchorScrollPosition(
      physics: physics,
      context: context,
      initialPixels: initialScrollOffset,
      keepScrollOffset: keepScrollOffset,
      oldPosition: oldPosition,
      debugLabel: debugLabel,
      controller: this,
    );
  }
}

class _AnchorScrollPosition extends SmoothScrollPosition {
  _AnchorScrollPosition({
    required super.physics,
    required super.context,
    super.initialPixels,
    super.keepScrollOffset,
    super.oldPosition,
    super.debugLabel,
    required this.controller,
  });

  final _AnchorScrollController controller;

  @override
  bool correctForNewDimensions(
    ScrollMetrics oldPosition,
    ScrollMetrics newPosition,
  ) {
    // 先让默认逻辑按新尺寸调整一次（越界回收、边界回弹那些）
    final bool settled = super.correctForNewDimensions(
      oldPosition,
      newPosition,
    );
    final double? target = controller.pendingPixels;
    if (target == null) {
      return settled;
    }
    controller.pendingPixels = null;
    final double clamped = target.clamp(
      newPosition.minScrollExtent,
      newPosition.maxScrollExtent,
    );
    if ((clamped - pixels).abs() <= 0.01) {
      return settled;
    }
    correctPixels(clamped);
    // 返回 false = 「位置变了，请用新偏移再排一次」。视口会在**同一帧内**
    // 重排，所以屏幕上不会出现「先画在旧位置、下一帧再跳回来」那一帧
    return false;
  }
}

class _AlphabetGridViewState<T> extends State<AlphabetGridView<T>> {
  final _AnchorScrollController _controller = _AnchorScrollController();

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

  /// 上一次布局用的几何与分段偏移：开关侧栏 / 拉动窗口时靠它还原锚点
  AlphabetGridMetrics? _lastMetrics;
  List<double> _lastSectionOffsets = const <double>[];
  List<int> _lastCounts = const <int>[];

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

  /// [index] 段的标题贴到视口顶部。
  ///
  /// 按住导航条滑动时用 `animate: false`：连续换段时每段都起 220ms 动画会
  /// 「追不上手指」，看着像卡住。
  void _jumpTo(int index, {bool animate = true}) {
    if (!_controller.hasClients ||
        index < 0 ||
        index >= _sectionOffsets.length) {
      return;
    }
    final double target = _sectionOffsets[index].clamp(
      0.0,
      _controller.position.maxScrollExtent,
    );
    if (!animate) {
      _controller.jumpTo(target);
      return;
    }
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

  /// 按新几何把「顶上那一条」换算成新的滚动像素，交给 [ScrollPosition] 在
  /// **布局阶段**落笔（见 [_AnchorScrollPosition]）。
  ///
  /// 不在帧后再 jumpTo：那样这一帧会先画错、下一帧才跳回来，侧栏动画里每帧
  /// 一次，看起来就是卡片快速上下浮动。
  void _queueAnchorRestore(
    AlphabetGridMetrics previous,
    AlphabetGridMetrics metrics,
    List<double> offsets,
  ) {
    final double before = _controller.offset;
    final AlphabetScrollAnchor? anchor = alphabetAnchorAt(
      previous,
      _lastSectionOffsets,
      _lastCounts,
      before,
    );
    if (anchor == null) {
      return;
    }
    _controller.pendingPixels = alphabetOffsetOf(metrics, offsets, anchor);
  }

  /// 把滚动区按 [width] 摆好：比可用宽度宽就裁掉右侧（等侧栏动画把地方让
  /// 出来），窄就在右边留白（等侧栏动画收回去）。两者在动画结束时都刚好归零。
  ///
  /// **始终**套同一层包装：条件性地插入 / 摘掉 `ClipRect` 会让下面的
  /// `Scrollable` 换一个位置、整棵子树重新挂载，滚动位置和
  /// `_AnchorScrollPosition` 里的几何记忆随之作废，切换侧栏后就会跳到别的段。
  Widget _fitToPlan({
    required double width,
    required BoxConstraints constraints,
    required Widget child,
  }) {
    final double height = constraints.hasBoundedHeight
        ? constraints.maxHeight
        : 0;
    if (!constraints.hasBoundedHeight) {
      return child;
    }
    return ClipRect(
      child: OverflowBox(
        alignment: Alignment.topLeft,
        minWidth: width,
        maxWidth: width,
        minHeight: height,
        maxHeight: height,
        child: SizedBox(width: width, height: height, child: child),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final List<AlphabetBucket<T>> buckets = _grouped();
    final List<String> letters = <String>[
      for (final AlphabetBucket<T> bucket in buckets) bucket.letter,
    ];

    // 侧栏开关是 220ms 的宽度动画，内容区每一帧都在变宽变窄。列数要是跟着
    // 每一帧的宽度走，动画中途总有一帧会多挤出一列、卡片又重新均分一次，
    // 看着就是「抽一下」。所以这里按**终态**宽度排布：侧栏状态一变就切到
    // 目标几何，动画期间多出来的宽度留白、不够的部分裁掉，等动画走完正好对上。
    return ValueListenableBuilder<bool>(
      valueListenable: LibraryRail.expandedNotifier,
      builder: (BuildContext context, bool railExpanded, Widget? _) {
        return LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            // 曲库页里「窗口宽 - 内容区宽」正好是侧栏宽 + 固定损耗，动画期间
            // 落在两者之间；独立使用（测试或别的容器）时这个关系不成立，那就
            // 按当前宽度老实排布，别去猜终态。
            final double chromeNow =
                MediaQuery.sizeOf(context).width - constraints.maxWidth;
            final bool inPageShell =
                chromeNow >= LibraryRail.collapsedWidth + _windowChrome - 1 &&
                chromeNow <= LibraryRail.expandedWidth + _windowChrome + 1;
            final double planWidth = inPageShell
                ? MediaQuery.sizeOf(context).width -
                      (railExpanded
                          ? LibraryRail.expandedWidth
                          : LibraryRail.collapsedWidth) -
                      _windowChrome
                : constraints.maxWidth;
            final AlphabetGridMetrics metrics = AlphabetGridMetrics(
              // 卡片不许跑到导航条底下，横向先把它让出来。
              // 左侧那 10 只作为 SliverPadding 的缩进，不参与列数换算 ——
              // 列数一变，每段行数跟着变，侧栏开关时的锚点也全都要重算
              viewportWidth: math.max(0, planWidth - gridRightReserve),
              tileWidth: widget.tileWidth,
              crossAxisSpacing: widget.crossAxisSpacing,
              mainAxisSpacing: widget.mainAxisSpacing,
              tileHeight: widget.tileHeight,
              headerExtent: alphabetHeaderExtent,
              topPadding: widget.topPadding,
            );
            final List<int> counts = <int>[
              for (final AlphabetBucket<T> bucket in buckets) bucket.length,
            ];
            final List<double> offsets = metrics.sectionOffsets(counts);

            // 几何变了（开关侧栏时行高连续变化、拉窗口时列数也可能变）：先记下
            // 「现在顶上是谁」，布局完再放回去。每帧都取一次当前偏移、换算回同一个
            // 锚点，所以是一条自洽的迭代，不会越修越偏。
            //
            // 判据是「宽度有没有变」，**不能**用「行高变化超过半像素」：侧栏是缓动
            // 曲线，首尾每帧只变零点几像素，那种帧会被漏掉、错位攒起来，表现为
            // 动画开头和结尾各跳一小下。
            final AlphabetGridMetrics? previous = _lastMetrics;
            if (previous != null &&
                _lastSectionOffsets.isNotEmpty &&
                _controller.hasClients &&
                (previous.viewportWidth != metrics.viewportWidth ||
                    previous.crossAxisCount != metrics.crossAxisCount ||
                    previous.tileHeight != metrics.tileHeight)) {
              _queueAnchorRestore(previous, metrics, offsets);
            }
            _lastMetrics = metrics;
            _lastSectionOffsets = offsets;
            _lastCounts = counts;
            _sectionOffsets = offsets;
            _scheduleActiveSync();

            final Widget scroller = NotificationListener<ScrollNotification>(
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
                      padding: const EdgeInsets.only(
                        left: alphabetGridLeftInset,
                        right: gridRightReserve,
                      ),
                      sliver: SliverGrid(
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: metrics.crossAxisCount,
                          mainAxisSpacing: widget.mainAxisSpacing,
                          crossAxisSpacing: widget.crossAxisSpacing,
                          mainAxisExtent: metrics.childMainAxisExtent,
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
            );

            return Stack(
              children: <Widget>[
                _fitToPlan(
                  width: planWidth,
                  constraints: constraints,
                  child: scroller,
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
                          _jumpTo(letters.indexOf(letter), animate: false);
                        },
                      );
                    },
                  ),
                ),
              ],
            );
          },
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
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 最右侧的字母导航条：`A`…`Z` 再接 `#`。
///
/// 鼠标按住后上下滑动就跟着走（不是只有点一下才跳，按住时左边弹一个放大的
/// 当前字母）。桌面端没有触摸屏那种「手指压住」的反馈，气泡是唯一提示。
class AlphabetRail extends StatefulWidget {
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
  State<AlphabetRail> createState() => _AlphabetRailState();
}

class _AlphabetRailState extends State<AlphabetRail> {
  /// 按住时手指 / 鼠标落在哪一段；null 表示没按住
  String? _pressed;

  void _selectAt(Offset local, double rowHeight) {
    if (widget.letters.isEmpty) {
      return;
    }
    final int index = (local.dy / rowHeight).floor().clamp(
      0,
      widget.letters.length - 1,
    );
    final String letter = widget.letters[index];
    if (letter == _pressed) {
      return;
    }
    setState(() => _pressed = letter);
    widget.onSelect(letter);
  }

  void _release() {
    if (_pressed == null) {
      return;
    }
    setState(() => _pressed = null);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.letters.isEmpty) {
      return const SizedBox.shrink();
    }
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        // 高度不够时按均分缩小，宁可字小一点也不能溢出
        final double rowHeight = math.min(
          18,
          constraints.maxHeight / widget.letters.length,
        );
        final double total = rowHeight * widget.letters.length;
        final int pressedIndex = _pressed == null
            ? -1
            : widget.letters.indexOf(_pressed!);
        return Align(
          alignment: Alignment.center,
          child: SizedBox(
            width: railWidth,
            height: total,
            // 气泡要越出这根窄条，Stack 默认会裁掉
            child: Stack(
              clipBehavior: Clip.none,
              children: <Widget>[
                Listener(
                  behavior: HitTestBehavior.opaque,
                  onPointerDown: (PointerDownEvent event) =>
                      _selectAt(event.localPosition, rowHeight),
                  // 按下后指针移出去也还归这里：pointer 路由是按下时定的
                  onPointerMove: (PointerMoveEvent event) =>
                      _selectAt(event.localPosition, rowHeight),
                  onPointerUp: (PointerUpEvent event) => _release(),
                  onPointerCancel: (PointerCancelEvent event) => _release(),
                  child: MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        for (final String letter in widget.letters)
                          _RailLetter(
                            letter: letter,
                            height: rowHeight,
                            active:
                                letter == widget.active || letter == _pressed,
                          ),
                      ],
                    ),
                  ),
                ),
                if (pressedIndex >= 0)
                  Positioned(
                    // 气泡挂在字母左边：导航条只有 22 宽，放里面会盖住字母
                    right: railWidth + 10,
                    top: pressedIndex * rowHeight + rowHeight / 2 - 20,
                    child: IgnorePointer(
                      child: Container(
                        width: 40,
                        height: 40,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: scheme.primary,
                          shape: BoxShape.circle,
                          boxShadow: <BoxShadow>[
                            BoxShadow(
                              color: scheme.shadow.withValues(alpha: 0.3),
                              blurRadius: 10,
                              offset: const Offset(0, 3),
                            ),
                          ],
                        ),
                        child: Text(
                          _pressed!,
                          key: const ValueKey<String>('alphabet-rail-bubble'),
                          style: TextStyle(
                            fontSize: 20,
                            height: 1,
                            fontWeight: FontWeight.w700,
                            color: scheme.onPrimary,
                          ),
                        ),
                      ),
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

class _RailLetter extends StatelessWidget {
  const _RailLetter({
    required this.letter,
    required this.height,
    required this.active,
  });

  final String letter;
  final double height;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return SizedBox(
      key: ValueKey<String>('alphabet-rail-$letter'),
      height: height,
      width: railWidth,
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
    );
  }
}
