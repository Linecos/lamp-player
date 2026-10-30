import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart' show PointerEnterEvent, PointerExitEvent;
import 'package:clock/clock.dart';
import 'package:flutter/material.dart';

import '../../common/formatters/duration.dart';
import '../../common/widgets/album_cover.dart';
import '../../common/widgets/cover_shape.dart';
import '../../common/widgets/slider_semantics_scope.dart';
import '../../common/widgets/wheel_step.dart';
import '../../rust/api/lyrics.dart';
import 'spectrum_bars.dart';
import '../../rust/api/model.dart';
import '../library/library_sort.dart';
import 'lyrics_view.dart';
import 'playback_mode.dart';
import 'playback_queue.dart';

/// 加载一首曲目的歌词；不注入时播放条不显示歌词预览。
typedef TrackLyricsLoader = Future<TrackLyrics> Function(String path);

/// 请播放条把音量浮层弹出来一下。
///
/// 音量条平时只在悬停时出现；用 Ctrl+↑ / Ctrl+↓ 调音量时若只换图标，
/// 看不出当前百分比。浮层本身仍归 `_VolumeControl` 的 `OverlayPortal` 管，
/// 这里只发「展示一下」的信号，免得把控制器暴露给页面。
class VolumePanelPeek extends ChangeNotifier {
  void peek() => notifyListeners();
}

/// 底部播放条：曲目信息、上一首 / 播放暂停 / 下一首、进度、音量与队列入口。
///
/// 布局是经典三段式：左「封面 + 曲名（+ 当前歌词）」与右「时间 + 进度 +
/// 模式 + 音量」各占 flex 1（等宽），中间是三键 —— 两侧等宽，播放键才真正
/// 落在整条播放条的中轴上。
///
/// 右段宽度不够时逐级收：模式按钮 → 音量滑块 → 总时长，宽度永远先给进度条。
class PlayerBar extends StatelessWidget {
  /// 岛卡片高度，不含外边距。
  static const double cardHeight = 88;

  /// 卡片上方留的一点呼吸空间。
  static const double cardTopPadding = 8;

  /// 卡片底部外边距：岛贴窗口底，留一点呼吸空间。
  static const double cardBottomMargin = 12;

  /// 岛在窗口底部占用的总高度。
  ///
  /// 曲库页的列表把底部留白设成它 + 8：列表可以一直滚到岛下面（悬浮感），
  /// 但滚到底时最后一行停在岛上方，不会被压住。
  static const double occupiedHeight =
      cardTopPadding + cardHeight + cardBottomMargin;

  const PlayerBar({
    super.key,
    required this.isPlaying,
    required this.isAvailable,
    this.canSeek = true,
    required this.position,
    required this.duration,
    this.volume = 1,
    this.track,
    this.onPlayPause,
    this.onPrevious,
    this.onNext,
    this.onSeekStart,
    this.onSeekChanged,
    this.onSeekEnd,
    this.onVolumeChanged,
    this.onToggleMute,
    this.onShowQueue,
    this.repeat = LoopMode.off,
    this.shuffle = false,
    this.onCyclePlayMode,
    this.onOpenNowPlaying,
    this.lyricsLoader,
    this.spectrum,
    this.volumePanelPeek,
  });

  /// 频谱数据：传了才在曲名右侧显示迷你条（测试不注入就不画）
  final ValueListenable<List<double>>? spectrum;

  /// 键盘调音量时用来弹出音量浮层；不传则只有悬停才显示
  final VolumePanelPeek? volumePanelPeek;

  /// 当前曲目的歌词来源；不传时左段只显示曲名 / 艺术家
  final TrackLyricsLoader? lyricsLoader;

  final Track? track;
  final bool isPlaying;
  final bool isAvailable;

  /// 是否允许拖动进度：播放中 / 暂停中为 true，停止（含播完）为 false，
  /// 否则拖动只会改位置、播放键却从头重播。
  final bool canSeek;

  final double position;
  final double duration;

  /// 当前音量，`0.0..=1.0`。
  final double volume;

  final VoidCallback? onPlayPause;

  /// 上一首 / 下一首；为空或没有曲目时按钮禁用。
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;

  /// 打开播放队列面板。
  final VoidCallback? onShowQueue;

  final LoopMode repeat;
  final bool shuffle;

  /// 顺序 / 随机 / 列表循环 / 单曲循环四态轮换
  final VoidCallback? onCyclePlayMode;

  /// 开始拖动进度：上游应暂停位置轮询，否则轮询值会把滑块拉回去。
  final ValueChanged<double>? onSeekStart;

  /// 拖动中的预览位置（秒），用于让时间标签实时跟随。
  final ValueChanged<double>? onSeekChanged;

  /// 松手后的目标位置（秒）。
  final ValueChanged<double>? onSeekEnd;

  final ValueChanged<double>? onVolumeChanged;

  final VoidCallback? onToggleMute;

  /// 点封面 / 曲名打开「正在播放」页
  final VoidCallback? onOpenNowPlaying;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final Track? current = track;
    final bool canControl = isAvailable && current != null;
    final double total = duration > 0 ? duration : 0;
    final double shown = position.clamp(0.0, total).toDouble();

    return Padding(
      // margin 必须放在外层：直接给 Container.margin 时，Column 的 loose
      // 约束会让 Row 先按整宽布局、再加 margin 外扩，右侧会被裁掉 16px
      padding: const EdgeInsets.fromLTRB(
        16,
        cardTopPadding,
        16,
        cardBottomMargin,
      ),
      child: SizedBox(
        height: cardHeight,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(32),
            border: Border.all(color: scheme.outlineVariant),
            boxShadow: <BoxShadow>[
              // 阴影向下收窄：offset 6 配 blur 18 会向上扩散 12px，
              // 盖住列表最后一行的悬停高亮
              BoxShadow(
                color: scheme.shadow.withValues(alpha: 0.06),
                blurRadius: 10,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          // 底色在 Container 上，墨水层要单独垫一层透明 Material 才画得出来。
          child: Material(
            type: MaterialType.transparency,
            child: Row(
              children: <Widget>[
                Expanded(
                  child: _PlayerBarLeft(
                    track: current,
                    isPlaying: isPlaying,
                    isAvailable: isAvailable,
                    position: shown,
                    lyricsLoader: lyricsLoader,
                    onOpenNowPlaying: onOpenNowPlaying,
                    spectrum: spectrum,
                  ),
                ),
                // 中段宽度固定、两侧 Expanded 等宽 → 三键落在整条中轴上
                _center(context, canControl: canControl),
                Expanded(
                  child: _right(
                    context,
                    canControl: canControl,
                    shown: shown,
                    total: total,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 中段：上一首 / 播放暂停 / 下一首
  Widget _center(BuildContext context, {required bool canControl}) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        _BarIconButton(
          icon: Icons.skip_previous,
          tooltip: '上一首 (Ctrl+←)',
          size: 36,
          onPressed: canControl ? onPrevious : null,
        ),
        IconButton.filled(
          onPressed: canControl ? onPlayPause : null,
          tooltip: isPlaying ? '暂停 (空格)' : '播放 (空格)',
          iconSize: 24,
          style: IconButton.styleFrom(
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          constraints: const BoxConstraints.tightFor(width: 40, height: 40),
          padding: EdgeInsets.zero,
          icon: Icon(isPlaying ? Icons.pause : Icons.play_arrow),
        ),
        _BarIconButton(
          icon: Icons.skip_next,
          tooltip: '下一首 (Ctrl+→)',
          size: 36,
          onPressed: canControl ? onNext : null,
        ),
      ],
    );
  }

  /// 右段：时间 + 进度 + 随机 / 循环 / 队列 + 音量
  ///
  /// 三段式把右段压到最小窗口约 215px、默认窗口约 546px，全塞进去会挤爆，
  /// 所以按可用宽度分档：先收总时长，再收当前时间。音量条改成悬停浮层后
  /// 不占常驻宽度，模式与队列两个按钮始终保留（合并成菜单要点两下才能切模式）。
  Widget _right(
    BuildContext context, {
    required bool canControl,
    required double shown,
    required double total,
  }) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final TextStyle timeStyle =
        (theme.textTheme.labelMedium ?? const TextStyle()).copyWith(
          color: scheme.onSurfaceVariant,
          fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
        );

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double width = constraints.maxWidth;
        // 300 以下先收总时长：模式与队列各占一个按钮后右侧更挤，
        // 进度条是主操作，总时长还能从进度条末端推出来
        final bool showTotal = width >= 300;
        // 再窄连时间标签也去掉（窗口下限 900 时不会触发，纯兜底）
        final bool showTime = width >= 160;
        // 音量条改成悬停浮层后不再占常驻宽度：进度条吃掉这块宽度，
        // 右侧图标自然靠到岛的内边距上，和左段对称
        const double buttonSize = 32;

        return Row(
          children: <Widget>[
            if (showTime) ...<Widget>[
              Text(formatDuration(shown), style: timeStyle),
              const SizedBox(width: 8),
            ],
            Expanded(
              child: SizedBox(
                // Slider 默认 48 高，压到 28 才塞得进 88 的播放条
                height: 28,
                child: _SlimSlider(
                  key: const ValueKey<String>('player-progress'),
                  value: shown,
                  max: total > 0 ? total : 1,
                  enabled: canControl && canSeek && total > 0,
                  onChangeStart: onSeekStart,
                  onChanged: onSeekChanged,
                  onChangeEnd: onSeekEnd,
                ),
              ),
            ),
            if (showTotal) ...<Widget>[
              const SizedBox(width: 8),
              Text(formatDuration(total), style: timeStyle),
            ],
            const SizedBox(width: 4),
            // 播放模式与队列始终各占一个按钮：合并成菜单后要点两下才能切模式
            _BarIconButton(
              icon: playbackModeIcon(repeat, shuffle),
              tooltip: '播放模式：${playbackModeLabel(repeat, shuffle)}',
              size: buttonSize,
              selected: playbackModeActive(repeat, shuffle),
              onPressed: onCyclePlayMode,
            ),
            _BarIconButton(
              icon: Icons.queue_music,
              tooltip: '播放队列',
              size: buttonSize,
              onPressed: onShowQueue,
            ),
            const SizedBox(width: 4),
            _VolumeControl(
              volume: volume,
              enabled: isAvailable,
              size: buttonSize,
              onChanged: onVolumeChanged,
              onToggleMute: onToggleMute,
              peek: volumePanelPeek,
            ),
          ],
        );
      },
    );
  }
}

/// 左段：封面 + 曲名 / 艺术家，宽窗口时再补一句当前歌词。
///
/// 歌词单独做成 `StatefulWidget`：播放位置每几百毫秒推一次，只有这里需要按
/// 位置重算当前行，没必要把三键 / 进度 / 音量一起卷进重建。
class _PlayerBarLeft extends StatefulWidget {
  const _PlayerBarLeft({
    required this.track,
    required this.isPlaying,
    required this.isAvailable,
    required this.position,
    required this.lyricsLoader,
    required this.onOpenNowPlaying,
    this.spectrum,
  });

  /// 迷你频谱的数据源；为空时不占位
  final ValueListenable<List<double>>? spectrum;

  final Track? track;
  final bool isPlaying;
  final bool isAvailable;

  /// 当前播放位置（秒），用来定位歌词行
  final double position;

  final TrackLyricsLoader? lyricsLoader;
  final VoidCallback? onOpenNowPlaying;

  @override
  State<_PlayerBarLeft> createState() => _PlayerBarLeftState();
}

class _PlayerBarLeftState extends State<_PlayerBarLeft> {
  /// 切歌会来回切（上一首 / 下一首），缓存最近几首的歌词免得重复解析
  static const int _cacheLimit = 8;

  /// 歌词够宽才占位：再窄曲名和歌词会互相挤到只剩几个字
  static const double _lyricMinWidth = 340;

  /// 封面边长：算曲名最大宽度时要用
  static const double _coverSize = 56;

  final Map<String, TrackLyrics> _cache = <String, TrackLyrics>{};

  TrackLyrics? _lyrics;

  /// 已经发起过加载的曲目，避免每次位置刷新都重新读一遍
  String? _loadedPath;

  /// 递增令牌：切歌后旧的加载结果直接丢掉
  int _request = 0;

  /// 读失败过的曲目 → 何时允许再试。
  ///
  /// 以前失败后 `_loadedPath` 还留着，同一首歌（只要不切歌）就再也不会重试，
  /// 播放条会一直空白——文件被占用一次就够了。这里给失败留一个冷却窗口，
  /// 到点后由下一次 widget 更新重新发起请求。
  final Map<String, DateTime> _retryAfter = <String, DateTime>{};

  /// 失败后的冷却时长：太短会对着坏文件反复解析，太长等于不重试
  static const Duration _retryDelay = Duration(seconds: 30);

  @override
  void initState() {
    super.initState();
    _syncTrack();
  }

  @override
  void didUpdateWidget(covariant _PlayerBarLeft oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 路径没变也可能需要重试（上一轮读失败过），所以这里不做短路：
    // `_syncTrack` 内部只有一次字符串比较，命中了才真的读歌词
    _syncTrack();
  }

  void _syncTrack() {
    final String? path = widget.track?.path;
    if (path == null) {
      // 停止 / 清空队列：别把上一首的歌词留在播放条上
      _request += 1;
      _loadedPath = null;
      _lyrics = null;
      return;
    }
    if (path == _loadedPath) {
      return;
    }
    final DateTime? retryAt = _retryAfter[path];
    if (retryAt != null) {
      if (clock.now().isBefore(retryAt)) {
        return;
      }
      // 冷却到点：清掉标记，重新走一遍加载
      _retryAfter.remove(path);
    }
    _loadedPath = path;
    _request += 1;
    final TrackLyrics? cached = _cache.remove(path);
    if (cached != null) {
      // 命中缓存：重新插回队尾，保持 LRU 顺序
      _cache[path] = cached;
      _lyrics = cached;
      return;
    }
    _lyrics = null;
    final TrackLyricsLoader? loader = widget.lyricsLoader;
    if (loader != null) {
      unawaited(_load(loader, path, _request));
    }
  }

  Future<void> _load(TrackLyricsLoader loader, String path, int token) async {
    TrackLyrics? result;
    try {
      result = await loader(path);
    } catch (error) {
      // 歌词缺失不该影响播放：读失败就当这首没有歌词。
      // 但要把「已加载」标记清掉，否则这首直到切歌都不会再试一次。
      debugPrint('读取播放条歌词失败：$error');
      if (mounted && token == _request) {
        _loadedPath = null;
        _retryAfter[path] = clock.now().add(_retryDelay);
      }
      return;
    }
    if (!mounted || token != _request) {
      return;
    }
    _cache[path] = result;
    while (_cache.length > _cacheLimit) {
      _cache.remove(_cache.keys.first);
    }
    setState(() => _lyrics = result);
  }

  /// 当前应显示的歌词：间奏空行往前找最近一句有字的，避免预览闪成空白
  String _currentLyric() {
    final List<LyricLine> lines = _lyrics?.lines ?? const <LyricLine>[];
    int index = lyricIndexAt(lines, widget.position);
    while (index >= 0 && lines[index].text.trim().isEmpty) {
      index -= 1;
    }
    return index < 0 ? '' : lines[index].text.trim();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final Track? current = widget.track;
    final String subtitle = current != null
        ? trackArtist(current)
        : (widget.isAvailable ? '从曲库中选一首开始' : '播放引擎不可用');

    final Widget titleBlock = Align(
      alignment: Alignment.centerLeft,
      child: InkWell(
        key: const ValueKey<String>('player-bar-open-now-playing-title'),
        borderRadius: BorderRadius.circular(12),
        hoverColor: scheme.onSurface.withValues(alpha: 0.08),
        onTap: current == null ? null : widget.onOpenNowPlaying,
        // Align 让高亮收缩到文字块大小，而不是整行高度
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                current?.title ?? '尚未播放',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleSmall,
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final bool showLyric =
            (_lyrics?.lines.isNotEmpty ?? false) &&
            constraints.maxWidth >= _lyricMinWidth;

        return Row(
          children: <Widget>[
            // 封面可点：打开正在播放页（歌词 / 大封面）
            // 高亮只包封面本身：把 12px 间距放进 InkWell 会让高亮比封面
            // 宽出一截，看起来和封面错位
            ValueListenableBuilder<bool>(
              valueListenable: circularCovers,
              builder: (BuildContext context, bool circular, Widget? child) {
                return InkWell(
                  key: const ValueKey<String>('player-bar-open-now-playing'),
                  // 圆形封面时高亮也得是圆的，否则四角会露出方形底色
                  borderRadius: BorderRadius.circular(
                    circular ? _coverSize / 2 : 16,
                  ),
                  hoverColor: scheme.onSurface.withValues(alpha: 0.08),
                  onTap: current == null ? null : widget.onOpenNowPlaying,
                  child: child,
                );
              },
              child: AlbumCover(
                path: current?.coverPath,
                size: _coverSize,
                radius: 16,
                playing: widget.isPlaying,
              ),
            ),
            const SizedBox(width: 12),
            // 曲名与歌词各占一半：歌词区域宽度固定，换歌时居中位置不会跟着
            // 标题长短左右跳
            Expanded(child: titleBlock),
            if (showLyric) ...<Widget>[
              const SizedBox(width: 12),
              Expanded(child: _LyricPreview(text: _currentLyric())),
            ],
            // 迷你频谱：贴着左段右缘；宽度不够时不画，免得挤成一条竖线
            if (widget.spectrum != null &&
                constraints.maxWidth >= 280) ...<Widget>[
              const SizedBox(width: 12),
              SizedBox(
                width: 46,
                child: SpectrumBars(
                  key: const ValueKey<String>('player-bar-spectrum'),
                  bands: widget.spectrum!,
                  height: 22,
                  barWidth: 3,
                  gap: 2,
                  barCount: 8,
                  minBar: 1,
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}

/// 播放条上的一句歌词：换行时淡入 + 上滑
class _LyricPreview extends StatelessWidget {
  const _LyricPreview({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;

    return SizedBox(
      key: const ValueKey<String>('player-bar-lyric'),
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 240),
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeInCubic,
        transitionBuilder: (Widget child, Animation<double> animation) {
          return FadeTransition(
            opacity: animation,
            child: SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0, 0.35),
                end: Offset.zero,
              ).animate(animation),
              child: child,
            ),
          );
        },
        // 与展开页一致：歌词居中。Stack 的每个子项（新行 / 旧行）各自居中，
        // 换行时两行不会互相顶到左边
        layoutBuilder: (Widget? current, List<Widget> previous) => Stack(
          alignment: Alignment.center,
          children: <Widget>[...previous, ?current],
        ),
        child: Text(
          text,
          // 空串也要换 key：间奏时切到空白，再切回来才重新淡入
          key: ValueKey<String>(text),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall?.copyWith(color: scheme.primary),
        ),
      ),
    );
  }
}

/// 播放条上的紧凑图标按钮：默认 40×40，避免默认 48 把控件挤出去。
class _BarIconButton extends StatelessWidget {
  const _BarIconButton({
    required this.icon,
    required this.tooltip,
    this.onPressed,
    this.selected = false,
    this.size = 40,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final bool selected;

  /// 按钮边长：窄窗口收到 32
  final double size;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return IconButton(
      onPressed: onPressed,
      tooltip: tooltip,
      isSelected: selected,
      iconSize: 20,
      // shrinkWrap：M3 默认把点击区撑到 48，会顶破三段式的固定宽度
      style: IconButton.styleFrom(
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      constraints: BoxConstraints.tightFor(width: size, height: size),
      padding: EdgeInsets.zero,
      icon: Icon(
        icon,
        color: selected ? scheme.primary : scheme.onSurfaceVariant,
      ),
    );
  }
}

/// 音量：图标常驻，悬停弹出竖条滑块；点击图标仍是静音切换。
///
/// 竖条放浮层而不是常驻：播放条右侧宽度紧张（最小窗口只剩两百多像素），
/// 常驻滑块会把进度条挤到几乎没法拖。
class _VolumeControl extends StatefulWidget {
  const _VolumeControl({
    required this.volume,
    required this.enabled,
    this.size = 40,
    this.onChanged,
    this.onToggleMute,
    this.peek,
  });

  final double volume;
  final bool enabled;

  /// 静音按钮边长，与其他按钮保持一致
  final double size;

  final ValueChanged<double>? onChanged;
  final VoidCallback? onToggleMute;

  /// 键盘调音量的信号源；收到就弹一次浮层
  final VolumePanelPeek? peek;

  @override
  State<_VolumeControl> createState() => _VolumeControlState();
}

class _VolumeControlState extends State<_VolumeControl> {
  final OverlayPortalController _portal = OverlayPortalController();
  final LayerLink _link = LayerLink();

  /// 指针是否停在按钮 / 浮层上；两者都不在时才收起
  bool _overButton = false;
  bool _overPanel = false;

  /// 收起延迟：从按钮移向浮层时会先经过一小段空隙，立刻收就没法用
  Timer? _hideTimer;

  /// 键盘调音量后浮层停留多久：足够看清百分比，又不至于一直挡着列表
  static const Duration _peekDuration = Duration(milliseconds: 1200);

  @override
  void initState() {
    super.initState();
    widget.peek?.addListener(_handlePeek);
  }

  @override
  void didUpdateWidget(covariant _VolumeControl oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.peek != widget.peek) {
      oldWidget.peek?.removeListener(_handlePeek);
      widget.peek?.addListener(_handlePeek);
    }
  }

  @override
  void dispose() {
    widget.peek?.removeListener(_handlePeek);
    _hideTimer?.cancel();
    super.dispose();
  }

  /// 键盘调音量：弹一次浮层并停留一会儿，鼠标不在上面也会自动收起
  void _handlePeek() {
    if (!mounted || !widget.enabled || widget.onChanged == null) {
      return;
    }
    _hideTimer?.cancel();
    if (!_portal.isShowing) {
      _portal.show();
    }
    _hideTimer = Timer(_peekDuration, () {
      if (!mounted || _overButton || _overPanel) {
        return;
      }
      if (_portal.isShowing) {
        _portal.hide();
      }
    });
  }

  void _syncVisibility() {
    _hideTimer?.cancel();
    if (_overButton || _overPanel) {
      if (!_portal.isShowing) {
        _portal.show();
      }
      return;
    }
    _hideTimer = Timer(const Duration(milliseconds: 140), () {
      if (!mounted || _overButton || _overPanel) {
        return;
      }
      if (_portal.isShowing) {
        _portal.hide();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final double level = widget.volume.clamp(0.0, 1.0);
    final bool showPanel = widget.enabled && widget.onChanged != null;

    return OverlayPortal(
      controller: _portal,
      overlayChildBuilder: (BuildContext context) => _panel(level),
      child: CompositedTransformTarget(
        link: _link,
        child: MouseRegion(
          onEnter: showPanel
              ? (PointerEnterEvent _) {
                  _overButton = true;
                  _syncVisibility();
                }
              : null,
          onExit: showPanel
              ? (PointerExitEvent _) {
                  _overButton = false;
                  _syncVisibility();
                }
              : null,
          child: IconButton(
            onPressed: widget.enabled ? widget.onToggleMute : null,
            tooltip: level > 0 ? '静音' : '取消静音',
            iconSize: 20,
            // 与其他播放条按钮同尺寸，否则图标间距会忽大忽小
            style: IconButton.styleFrom(
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            constraints: BoxConstraints.tightFor(
              width: widget.size,
              height: widget.size,
            ),
            padding: EdgeInsets.zero,
            color: scheme.onSurfaceVariant,
            icon: Icon(switch (level) {
              <= 0 => Icons.volume_off,
              < 0.5 => Icons.volume_down,
              _ => Icons.volume_up,
            }),
          ),
        ),
      ),
    );
  }

  /// 滚轮步进：夹在 0..1，端点上不重复下发
  void _nudge(double delta) {
    final ValueChanged<double>? onChanged = widget.onChanged;
    if (!widget.enabled || onChanged == null) {
      return;
    }
    final double next = (widget.volume + delta).clamp(0.0, 1.0);
    if ((next - widget.volume).abs() < 0.001) {
      return;
    }
    onChanged(next);
  }

  Widget _panel(double level) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final ThemeData theme = Theme.of(context);

    return Positioned(
      // 不给宽度的话 Material 会吃满 overlay 的约束，变成一整块蒙版
      width: 56,
      child: CompositedTransformFollower(
        link: _link,
        showWhenUnlinked: false,
        // 贴图标右侧对齐：静音图标在最右边，居中对齐会让浮层超出窗口被裁
        targetAnchor: Alignment.topRight,
        followerAnchor: Alignment.bottomRight,
        offset: const Offset(8, -8),
        child: MouseRegion(
          onEnter: (PointerEnterEvent _) {
            _overPanel = true;
            _syncVisibility();
          },
          onExit: (PointerExitEvent _) {
            _overPanel = false;
            _syncVisibility();
          },
          child: Material(
            elevation: 8,
            color: scheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(16),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 10),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    '${(level * 100).round()}%',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                      fontFeatures: const <FontFeature>[
                        FontFeature.tabularFigures(),
                      ],
                    ),
                  ),
                  const SizedBox(height: 6),
                  SizedBox(
                    width: 36,
                    height: 120,
                    child: WheelStep(
                      // 一格 10%：桌面播放器的常规粒度，拖拽仍是细调
                      onStep: (int direction) => _nudge(direction * 0.1),
                      // 竖过来：上端 100%，下端 0%
                      child: RotatedBox(
                        quarterTurns: 3,
                        child: _SlimSlider(
                          key: const ValueKey<String>('player-volume'),
                          value: level,
                          max: 1,
                          enabled: widget.enabled,
                          onChanged: widget.onChanged,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 扁平滑块：播放条的 88px 高度塞不下默认尺寸的 Slider。
class _SlimSlider extends StatelessWidget {
  const _SlimSlider({
    super.key,
    required this.value,
    required this.max,
    required this.enabled,
    this.onChangeStart,
    this.onChanged,
    this.onChangeEnd,
  });

  final double value;
  final double max;
  final bool enabled;
  final ValueChanged<double>? onChangeStart;
  final ValueChanged<double>? onChanged;
  final ValueChanged<double>? onChangeEnd;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final SliderThemeData base = SliderTheme.of(context);

    return SliderTheme(
      data: base.copyWith(
        trackHeight: 4,
        activeTrackColor: scheme.primary,
        inactiveTrackColor: scheme.surfaceContainerHighest,
        disabledActiveTrackColor: scheme.outlineVariant,
        disabledInactiveTrackColor: scheme.surfaceContainerHighest,
        thumbColor: scheme.primary,
        disabledThumbColor: scheme.outline,
        overlayColor: scheme.primary.withValues(alpha: 0.12),
        thumbShape: RoundSliderThumbShape(
          enabledThumbRadius: 7,
          disabledThumbRadius: 5,
        ),
        overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
        trackShape: const RoundedRectSliderTrackShape(),
      ),
      child: SliderSemanticsScope(
        child: Slider(
          value: value.clamp(0.0, max).toDouble(),
          max: max,
          onChangeStart: enabled ? onChangeStart : null,
          onChanged: enabled ? onChanged : null,
          onChangeEnd: enabled ? onChangeEnd : null,
        ),
      ),
    );
  }
}
