import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/immersive_chrome.dart';
import '../../common/formatters/duration.dart';
import '../../common/widgets/album_cover.dart';
import '../../common/widgets/slider_semantics_scope.dart';
import '../../rust/api/lyrics.dart' as lyrics_api;
import '../../rust/api/model.dart';
import '../../rust/api/player.dart' as rust;
import '../../theme/app_theme.dart';
import '../library/library_sort.dart' show trackArtist;
import 'cover_palette.dart';
import 'lyrics_view.dart';
import 'playback_mode.dart';
import 'playback_queue.dart';
import 'shortcuts.dart';
import 'spectrum_wave.dart';
import 'widgets/cover_flow_background.dart';

/// 正在播放页的实时快照。
///
/// 由曲库页在进度刷新时推过来（同一个 notifier 兼顾播放 / 暂停 / 切歌），
/// 页面自己不轮询，避免两套状态各跑一份。
class NowPlayingData {
  const NowPlayingData({
    this.track,
    this.isPlaying = false,
    this.position = 0,
    this.duration = 0,
    this.isAvailable = false,
    this.volume = 1,
    this.repeat = LoopMode.off,
    this.shuffle = false,
  });

  final Track? track;
  final bool isPlaying;
  final double position;
  final double duration;
  final bool isAvailable;
  final double volume;
  final LoopMode repeat;
  final bool shuffle;
}

/// 歌词加载函数；测试可注入，避免落盘 / 依赖 Rust。
typedef LyricsLoader = Future<lyrics_api.TrackLyrics> Function(String path);

/// 正在播放页：大封面 + 曲目信息 + 同步歌词。
///
/// 歌词来源见 `rust/src/lyrics.rs`：同目录 `.lrc` 优先，其次内嵌标签。
/// 没有时间轴时按纯文本展示；点歌词行会 seek 到该行时间。
class NowPlayingPage extends StatefulWidget {
  const NowPlayingPage({
    super.key,
    required this.data,
    required this.onTogglePlay,
    required this.onPrevious,
    required this.onNext,
    required this.onSeek,
    this.onVolumeChanged,
    this.onToggleMute,
    this.onShowQueue,
    this.onCyclePlayMode,
    this.lyricsLoader,
    this.devices,
    this.selectedDevice,
    this.onSelectDevice,
    this.spectrum,
    this.onOpenEqualizer,
    this.animateBackground = false,
    this.shortcuts = kDefaultShortcuts,
  });

  /// 打开均衡器页；为空时不显示该按钮
  final VoidCallback? onOpenEqualizer;

  /// 频谱数据：传了才在歌词下层铺一条全宽音频丝带
  final ValueListenable<List<double>>? spectrum;

  /// 背景流光开关；默认关闭，生产入口显式开启，测试 / golden 保持静态。
  final bool animateBackground;

  /// 键位表；由曲库页透传，保证两页键位一致（见 `shortcuts.dart`）
  final List<ShortcutBinding> shortcuts;

  final ValueListenable<NowPlayingData> data;
  final Future<void> Function() onTogglePlay;
  final Future<void> Function() onPrevious;
  final Future<void> Function() onNext;
  final Future<void> Function(double seconds) onSeek;

  /// 音量 / 静音 / 队列 / 播放模式：不传时对应控件禁用
  final ValueChanged<double>? onVolumeChanged;
  final VoidCallback? onToggleMute;
  final VoidCallback? onShowQueue;
  final VoidCallback? onCyclePlayMode;

  /// 输出设备列表与当前选择：由曲库页用通知器推过来（本页是独立路由）
  final ValueListenable<List<rust.PlayerDevice>>? devices;
  final ValueListenable<int>? selectedDevice;

  /// 选中某块声卡；为空表示不可切换
  final ValueChanged<int>? onSelectDevice;

  final LyricsLoader? lyricsLoader;

  @override
  State<NowPlayingPage> createState() => _NowPlayingPageState();
}

class _NowPlayingPageState extends State<NowPlayingPage> {
  /// 窄屏上下排时留给歌词的最小高度（含封面与歌词之间的 12px 间距）
  static const double _narrowLyricMinHeight = 132;

  lyrics_api.TrackLyrics? _lyrics;
  String? _loadedPath;
  bool _loading = false;

  /// 当前封面的取色结果；为空时背景用主题色兜底。
  List<Color>? _palette;

  /// 播放进度（秒）：歌词视图拿它做插值，拖动预览不碰它。
  final ValueNotifier<double> _position = ValueNotifier<double>(0);

  /// 当前曲目：只在切歌 / 曲目对象刷新时通知。
  ///
  /// 进度 tick 不碰它，所以歌词列表与封面不会每 500ms 重新布局。
  final ValueNotifier<Track?> _track = ValueNotifier<Track?>(null);

  /// 播放 / 暂停：只驱动封面的跳动图标，范围比整页小得多。
  final ValueNotifier<bool> _playing = ValueNotifier<bool>(false);

  /// 拖动中的预览位置：松手才真正 seek，避免一次拖动发出几十条命令。
  ///
  /// 用 notifier 而不是 setState：拖动时每移动一个像素都会重建整页，
  /// 歌词列表跟着重新布局。
  final ValueNotifier<double?> _dragPosition = ValueNotifier<double?>(null);

  /// 沉浸模式：长按播放键切换，只留封面 / 歌名 / 歌词与三个控制键。
  bool _immersive = false;

  /// 进入沉浸模式时的轻提示；退出不提示。
  OverlayEntry? _toastEntry;

  /// 播放键的位置锚点：提示框跟着它弹在正上方
  final LayerLink _toggleLink = LayerLink();

  /// Sleep timer：到点自动暂停。`null` 表示未开启。
  Timer? _sleepTimer;

  /// 到点时刻，用于在按钮上显示剩余时间
  DateTime? _sleepUntil;

  String? get _sleepTooltip {
    final DateTime? until = _sleepUntil;
    if (until == null) {
      return '睡眠定时';
    }
    final Duration left = until.difference(DateTime.now());
    if (left.inSeconds <= 0) {
      return '睡眠定时：即将暂停';
    }
    final int minutes = (left.inSeconds / 60).ceil();
    return '睡眠定时：还剩 $minutes 分钟';
  }

  void _onSleepSelected(_SleepOption option) {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    switch (option) {
      case _SleepOption.cancel:
        setState(() => _sleepUntil = null);
      case _SleepOption.endOfTrack:
        final Track? track = widget.data.value.track;
        final double duration = track?.durationSecs ?? 0;
        final double left = duration - _position.value;
        if (duration <= 0 || left <= 0.5) {
          // 没有时长（还在解析）或已经到最后：当成「下一首播完」
          _armSleep(const Duration(minutes: 1));
          return;
        }
        _armSleep(Duration(milliseconds: (left * 1000).round()));
      case _SleepOption.minutes15:
        _armSleep(const Duration(minutes: 15));
      case _SleepOption.minutes30:
        _armSleep(const Duration(minutes: 30));
      case _SleepOption.minutes45:
        _armSleep(const Duration(minutes: 45));
      case _SleepOption.minutes60:
        _armSleep(const Duration(hours: 1));
    }
  }

  void _armSleep(Duration delay) {
    _sleepTimer?.cancel();
    _sleepTimer = Timer(delay, _fireSleep);
    setState(() => _sleepUntil = DateTime.now().add(delay));
  }

  /// 到点：正在播就暂停（不停止，醒来点一下就能接着听）
  void _fireSleep() {
    _sleepTimer = null;
    if (!mounted) {
      return;
    }
    setState(() => _sleepUntil = null);
    if (widget.data.value.isPlaying) {
      unawaited(widget.onTogglePlay());
    }
    _showToast('睡眠定时已到，已暂停播放');
  }

  void _toggleImmersive() {
    final bool next = !_immersive;
    setState(() => _immersive = next);
    // 窗口按钮画在路由上层，只能靠全局开关联动
    immersiveMode.value = next;
    if (next) {
      _showToast('沉浸模式');
    }
  }

  void _showToast(
    String message, {
    LayerLink? link,
    Alignment targetAnchor = Alignment.topCenter,
    Alignment followerAnchor = Alignment.bottomCenter,
    Offset offset = const Offset(0, -14),
  }) {
    _removeToast();
    final OverlayState? overlay = Overlay.maybeOf(context);
    if (overlay == null) {
      return;
    }
    final OverlayEntry entry = OverlayEntry(
      // 锚在被点的按钮上：提示就弹在刚操作的位置旁边
      builder: (BuildContext context) => Positioned(
        left: 0,
        top: 0,
        child: CompositedTransformFollower(
          link: link ?? _toggleLink,
          showWhenUnlinked: false,
          targetAnchor: targetAnchor,
          followerAnchor: followerAnchor,
          offset: offset,
          child: _ImmersiveToast(message: message, onDone: _removeToast),
        ),
      ),
    );
    _toastEntry = entry;
    overlay.insert(entry);
  }

  void _removeToast() {
    final OverlayEntry? entry = _toastEntry;
    _toastEntry = null;
    entry?.remove();
  }

  @override
  void initState() {
    super.initState();
    widget.data.addListener(_onData);
    _onData();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 本页背景固定为深色；浅色模式下窗口按钮需要改成浅色图标
    forceLightWindowControls.value =
        Theme.of(context).brightness == Brightness.light;
  }

  @override
  void dispose() {
    forceLightWindowControls.value = false;
    widget.data.removeListener(_onData);
    _position.dispose();
    _track.dispose();
    _playing.dispose();
    _dragPosition.dispose();
    _sleepTimer?.cancel();
    // 离开页面必须复位：窗口按钮跟着这个开关隐，留着会让别的页面也看不到
    immersiveMode.value = false;
    _removeToast();
    super.dispose();
  }

  void _onData() {
    if (!mounted) {
      return;
    }
    final NowPlayingData data = widget.data.value;
    if (!identical(_track.value, data.track)) {
      _track.value = data.track;
    }
    if (_playing.value != data.isPlaying) {
      _playing.value = data.isPlaying;
    }
    if (_position.value != data.position) {
      _position.value = data.position;
    }
    _syncTrack();
    // 进度与播放态由各自的 builder 局部刷新。
    // 这里不再 setState：每 500ms 整页重建会让歌词列表跟着重新布局。
  }

  /// 音量步进（快捷键用）；夹在 0..1，与音量滑条同一约束
  double _volumeStep(double delta) =>
      (widget.data.value.volume + delta).clamp(0.0, 1.0);

  /// 方向键快进 / 快退：与拖动进度条走同一条下发路径（[NowPlayingPage.onSeek]）
  ///
  /// 位置取本地 `_position`（由曲库页每 500ms 推来），比 `widget.data.value`
  /// 更贴近用户按下那一刻；两端夹紧，退到 0 / 到头都不会发出越界 seek。
  Future<void> _seekBy(double delta) async {
    final double duration = widget.data.value.duration;
    if (duration <= 0) {
      return;
    }
    final double target = (_position.value + delta).clamp(0.0, duration);
    // 本地先跟上：曲库页每 500ms 才推一次快照，不更新的话连按三次 → 每次都从
    // 同一个旧位置算，实际只前进了 5 秒。真值随后由快照覆盖。
    _position.value = target;
    await widget.onSeek(target);
  }

  /// 切歌时重新读歌词与封面色；同一首不重复读
  void _syncTrack() {
    final Track? track = widget.data.value.track;
    final String? path = track?.path;
    if (path == null) {
      if (_loadedPath != null || _palette != null) {
        setState(() {
          _loadedPath = null;
          _lyrics = null;
          _palette = null;
        });
      }
      return;
    }
    if (path == _loadedPath) {
      return;
    }
    _loadedPath = path;
    _lyrics = null;
    if (_palette != null) {
      setState(() => _palette = null);
    }
    unawaited(_loadLyrics(path));
    unawaited(_loadPalette(track?.coverPath, path));
  }

  Future<void> _loadPalette(String? coverPath, String trackPath) async {
    final List<Color>? colors = await CoverPaletteCache.load(coverPath);
    if (!mounted || _loadedPath != trackPath) {
      return;
    }
    setState(() => _palette = colors);
  }

  Future<void> _loadLyrics(String path) async {
    setState(() => _loading = true);
    lyrics_api.TrackLyrics? result;
    try {
      final LyricsLoader loader =
          widget.lyricsLoader ??
          (String value) => lyrics_api.lyricsLoad(path: value);
      result = await loader(path);
    } catch (error) {
      debugPrint('读取歌词失败：$error');
    }
    if (!mounted || _loadedPath != path) {
      return;
    }
    setState(() {
      _lyrics = result;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData base = Theme.of(context);
    // 背景固定为深色高饱和，浅色模式也给本页套深色前景，避免深底深字。
    if (base.brightness == Brightness.dark) {
      return _buildPage(context);
    }
    return Theme(
      data: AppTheme.dark(base.colorScheme.primary),
      child: Builder(builder: _buildPage),
    );
  }

  Widget _buildPage(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;

    // 与曲库页共用 shortcuts.dart 里那张表：本页是独立路由，拿不到曲库页的
    // 绑定，必须自己再挂一份，否则进来之后空格、方向键全无响应。
    // 没有对应处理器的动作不会绑定（这页没有搜索框，所以 Ctrl+F 不生效）。
    final Map<ShortcutAction, VoidCallback> handlers =
        <ShortcutAction, VoidCallback>{
          ShortcutAction.togglePlay: () => unawaited(widget.onTogglePlay()),
          ShortcutAction.next: () => unawaited(widget.onNext()),
          ShortcutAction.previous: () => unawaited(widget.onPrevious()),
          ShortcutAction.seekForward: () => unawaited(_seekBy(5)),
          ShortcutAction.seekBackward: () => unawaited(_seekBy(-5)),
          ShortcutAction.mediaTogglePlay: () =>
              unawaited(widget.onTogglePlay()),
          ShortcutAction.mediaNext: () => unawaited(widget.onNext()),
          ShortcutAction.mediaPrevious: () => unawaited(widget.onPrevious()),
        };
    // 音量 / 静音是可选回调：没接就不绑定，避免按了没反应
    final ValueChanged<double>? onVolume = widget.onVolumeChanged;
    if (onVolume != null) {
      handlers[ShortcutAction.volumeUp] = () => onVolume(_volumeStep(0.05));
      handlers[ShortcutAction.volumeDown] = () => onVolume(_volumeStep(-0.05));
    }
    final VoidCallback? onMute = widget.onToggleMute;
    if (onMute != null) {
      handlers[ShortcutAction.toggleMute] = onMute;
    }
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        ...shortcutBindings(handlers, bindings: widget.shortcuts),
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            Navigator.of(context).maybePop(),
      },
      child: Focus(
        autofocus: true,
        child: MouseRegion(
          // 沉浸模式下顶部浮层靠它唤出；窗口外壳也更新同一份状态
          onHover: (PointerHoverEvent event) =>
              trackPointerNearTop(event.localPosition),
          child: Scaffold(
            backgroundColor: scheme.surfaceContainerLow,
            body: CoverFlowBackground(
              colors: _palette,
              animate: widget.animateBackground,
              child: SafeArea(
                // 标题条左上角让出了一段（LampTitleBar.defaultLeftInset），
                // header 可以贴住窗口顶端，与右侧窗口按钮齐平。
                child: Column(
                  children: <Widget>[
                    _header(context),
                    // 歌词区只监听「曲目」：进度 tick 不该重排整棵歌词列表
                    Expanded(
                      child: Stack(
                        fit: StackFit.expand,
                        children: <Widget>[
                          // 柱形频谱压在内容下层：铺满整宽、半透明、不吃手势。
                          // 放在 Stack 而不是 Column 里，是为了不占歌词的高度，
                          // 歌词照常滚动。固定 72 高、贴在控制区上方。
                          // 纯净（沉浸）模式下跟其它控件一起淡出：那一屏只剩封面
                          // 和歌词，频谱留着会抢戏。
                          if (widget.spectrum != null)
                            Positioned(
                              left: 0,
                              right: 0,
                              bottom: 6,
                              height: 72,
                              child: _fadeWhenImmersive(
                                chromeKey: const ValueKey<String>(
                                  'now-playing-spectrum',
                                ),
                                child: SpectrumWave(
                                  bands: widget.spectrum!,
                                  // 颜色默认由主题主色派生三段色相渐变
                                  color: scheme.primary,
                                ),
                              ),
                            ),
                          ValueListenableBuilder<Track?>(
                            valueListenable: _track,
                            builder: (
                              BuildContext context,
                              Track? track,
                              Widget? child,
                            ) => _body(context, track),
                          ),
                        ],
                      ),
                    ),
                    _controls(context),
                    const SizedBox(height: 12),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _header(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      key: const ValueKey<String>('now-playing-header'),
      // 贴住窗口顶端，中心 y≈24，与右侧窗口按钮（中心 y≈22）齐平
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: SizedBox(
        height: 48,
        child: AnimatedBuilder(
          animation: Listenable.merge(<Listenable>[
            immersiveMode,
            pointerNearTop,
          ]),
          // 沉浸模式下只保留封面 / 歌名 / 歌词，返回键与标题靠指针靠近顶端唤出
          builder: (BuildContext context, Widget? child) {
            final bool hidden = immersiveMode.value && !pointerNearTop.value;
            return IgnorePointer(
              ignoring: hidden,
              child: AnimatedOpacity(
                opacity: hidden ? 0 : 1,
                duration: const Duration(milliseconds: 160),
                curve: Curves.easeOut,
                child: child,
              ),
            );
          },
          child: Row(
            children: <Widget>[
              // 热区只覆盖箭头周围这一圈，标题文字不参与点击。
              IconButton(
                key: const ValueKey<String>('now-playing-collapse'),
                onPressed: () => Navigator.of(context).maybePop(),
                icon: const Icon(Icons.keyboard_arrow_down, size: 22),
                tooltip: '收起',
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints.tightFor(
                  width: 48,
                  height: 48,
                ),
              ),
              const SizedBox(width: 4),
              Text('正在播放', style: theme.textTheme.titleMedium),
            ],
          ),
        ),
      ),
    );
  }

  Widget _body(BuildContext context, Track? track) {
    if (track == null) {
      return Center(
        child: Text('还没有在播放的曲目', style: Theme.of(context).textTheme.bodyLarge),
      );
    }
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final bool wide = constraints.maxWidth >= 760;
        final double coverSize = wide ? 336 : 240;
        final Widget info = _trackInfo(context, track, coverSize);
        final Widget lyric = _lyricsView(context);
        if (wide) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(32, 8, 32, 0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                SizedBox(
                  width: 420,
                  child: Center(
                    child: SizedBox(width: coverSize, child: info),
                  ),
                ),
                const SizedBox(width: 32),
                Expanded(child: lyric),
              ],
            ),
          );
        }
        return Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 0),
          child: Column(
            children: <Widget>[
              // 窄屏封面和歌词上下排：封面最多占「高度 - 歌词最小高度」，
              // 否则矮窗口下 Column 会顶出可视区
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: (constraints.maxHeight - _narrowLyricMinHeight)
                      .clamp(0.0, double.infinity),
                ),
                child: info,
              ),
              const SizedBox(height: 12),
              Expanded(child: lyric),
            ],
          ),
        );
      },
    );
  }

  Widget _trackInfo(BuildContext context, Track track, double coverSize) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        // 左栏高度由窗口决定：封面拿分到的高度，放不下就自己缩，别把下面的
        // 标题 / 歌手顶出可视区（900×560 这种最小窗口）。只缩封面不缩文字，
        // 文字保持原生字号不发虚。
        Flexible(
          child: LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              final double available = constraints.maxHeight;
              return ValueListenableBuilder<bool>(
                valueListenable: _playing,
                builder: (BuildContext context, bool playing, Widget? child) {
                  final double size =
                      available.isFinite && available < coverSize
                      ? available
                      : coverSize;
                  return Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(20),
                      boxShadow: <BoxShadow>[
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.35),
                          blurRadius: 28,
                          spreadRadius: 2,
                          offset: const Offset(10, 12),
                        ),
                      ],
                    ),
                    child: AlbumCover(
                      path: track.coverPath,
                      size: size,
                      radius: 20,
                      playing: playing,
                    ),
                  );
                },
              );
            },
          ),
        ),
        const SizedBox(height: 20),
        Text(
          track.title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          trackArtist(track),
          style: theme.textTheme.bodyLarge?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
        if ((track.album ?? '').isNotEmpty) ...<Widget>[
          const SizedBox(height: 2),
          Text(
            track.album!,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );
  }

  Widget _lyricsView(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final lyrics_api.TrackLyrics? lyrics = _lyrics;

    if (_loading) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (lyrics == null || (lyrics.lines.isEmpty && lyrics.plain.isEmpty)) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.lyrics_outlined, size: 28, color: scheme.outline),
            const SizedBox(height: 8),
            Text(
              '暂无歌词',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '把同名 .lrc 放到歌曲旁边即可显示',
              style: theme.textTheme.bodySmall?.copyWith(color: scheme.outline),
            ),
          ],
        ),
      );
    }
    if (lyrics.lines.isEmpty) {
      // 无时间轴：整段展示，不跟随进度
      return SingleChildScrollView(
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 16),
        child: Text(
          lyrics.plain,
          style: theme.textTheme.bodyLarge?.copyWith(height: 1.7),
        ),
      );
    }

    return LyricsView(
      key: ValueKey<String>('lyrics-${_loadedPath ?? ''}'),
      lines: lyrics.lines,
      position: _position,
      playing: _playing,
      onSeek: widget.onSeek,
    );
  }

  /// 沉浸模式下把两侧控件淡出。
  ///
  /// 只改透明度、不摘出树：占位还在，中间三个键的位置就不会跳。
  Widget _fadeWhenImmersive({required Key chromeKey, required Widget child}) {
    final bool visible = !_immersive;
    return IgnorePointer(
      key: chromeKey,
      ignoring: !visible,
      child: ExcludeSemantics(
        excluding: !visible,
        child: AnimatedOpacity(
          opacity: visible ? 1 : 0,
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOut,
          child: child,
        ),
      ),
    );
  }

  Widget _volumeControl(BuildContext context, NowPlayingData data, bool ready) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final double volume = data.volume.clamp(0.0, 1.0).toDouble();
    final IconData icon = volume == 0
        ? Icons.volume_off
        : (volume < 0.5 ? Icons.volume_down : Icons.volume_up);

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        IconButton(
          key: const ValueKey<String>('now-playing-mute'),
          tooltip: volume == 0 ? '取消静音' : '静音',
          onPressed: ready ? widget.onToggleMute : null,
          iconSize: 22,
          icon: Icon(icon, color: scheme.onSurfaceVariant),
        ),
        SizedBox(
          width: 120,
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 3,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
            ),
            child: SliderSemanticsScope(
              child: Slider(
                key: const ValueKey<String>('now-playing-volume'),
                value: volume,
                max: 1,
                onChanged: ready && widget.onVolumeChanged != null
                    ? widget.onVolumeChanged
                    : null,
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// 播放控制区。
  ///
  /// 只有这一块监听进度（每 500ms 一次）：滑块 + 时间 + 播放键都是小控件，
  /// 重建成本远低于整页。拖动预览走 [_dragPosition]，连这一层也不必重建。
  Widget _controls(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;

    return ValueListenableBuilder<NowPlayingData>(
      valueListenable: widget.data,
      builder: (BuildContext context, NowPlayingData data, Widget? child) {
        final bool ready = data.isAvailable && data.track != null;
        final double total = data.duration > 0 ? data.duration : 0;

        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            children: <Widget>[
              // 沉浸模式连进度条一起收起，只留三个控制键
              AnimatedSize(
                duration: const Duration(milliseconds: 160),
                curve: Curves.easeOut,
                alignment: Alignment.topCenter,
                child: _immersive
                    ? const SizedBox(width: double.infinity)
                    : ValueListenableBuilder<double?>(
                        valueListenable: _dragPosition,
                        builder:
                            (
                              BuildContext context,
                              double? drag,
                              Widget? child,
                            ) {
                              final double shown = (drag ?? data.position)
                                  .clamp(0.0, total)
                                  .toDouble();
                              return Column(
                                children: <Widget>[
                                  SliderTheme(
                                    data: SliderTheme.of(context).copyWith(
                                      trackHeight: 4,
                                      thumbShape: const RoundSliderThumbShape(
                                        enabledThumbRadius: 7,
                                      ),
                                      overlayShape:
                                          const RoundSliderOverlayShape(
                                            overlayRadius: 14,
                                          ),
                                    ),
                                    child: SliderSemanticsScope(
                                      child: Slider(
                                        key: const ValueKey<String>(
                                          'now-playing-progress',
                                        ),
                                        value: total > 0 ? shown : 0,
                                        max: total > 0 ? total : 1,
                                        onChanged: ready && total > 0
                                            ? (double value) =>
                                                  _dragPosition.value = value
                                            : null,
                                        onChangeEnd: ready && total > 0
                                            ? (double value) {
                                                _dragPosition.value = null;
                                                unawaited(widget.onSeek(value));
                                              }
                                            : null,
                                      ),
                                    ),
                                  ),
                                  Padding(
                                    // 12 与上面滑块的 overlay 半径对齐，时间才落在轨道两端内侧
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 12,
                                    ),
                                    child: Row(
                                      mainAxisAlignment:
                                          MainAxisAlignment.spaceBetween,
                                      children: <Widget>[
                                        Text(
                                          formatDuration(shown),
                                          style: theme.textTheme.bodySmall,
                                        ),
                                        Text(
                                          formatDuration(total),
                                          style: theme.textTheme.bodySmall,
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              );
                            },
                      ),
              ),
              SizedBox(height: _immersive ? 0 : 4),
              Row(
                children: <Widget>[
                  Expanded(
                    child: _fadeWhenImmersive(
                      chromeKey: const ValueKey<String>(
                        'now-playing-chrome-volume',
                      ),
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: Padding(
                          padding: const EdgeInsets.only(right: 24),
                          child: _volumeControl(context, data, ready),
                        ),
                      ),
                    ),
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      IconButton(
                        key: const ValueKey<String>('now-playing-previous'),
                        iconSize: 30,
                        onPressed: ready
                            ? () => unawaited(widget.onPrevious())
                            : null,
                        icon: const Icon(Icons.skip_previous),
                      ),
                      const SizedBox(width: 12),
                      Tooltip(
                        // manual：长按要留给沉浸模式，别让 Tooltip 抢走手势
                        triggerMode: TooltipTriggerMode.manual,
                        message: _immersive
                            ? '播放 / 暂停（长按退出沉浸模式）'
                            : '播放 / 暂停（长按切换沉浸模式）',
                        child: CompositedTransformTarget(
                          link: _toggleLink,
                          child: GestureDetector(
                            onLongPress: ready ? _toggleImmersive : null,
                            child: IconButton.filled(
                              key: const ValueKey<String>('now-playing-toggle'),
                              iconSize: 34,
                              padding: const EdgeInsets.all(14),
                              onPressed: ready
                                  ? () => unawaited(widget.onTogglePlay())
                                  : null,
                              icon: Icon(
                                data.isPlaying ? Icons.pause : Icons.play_arrow,
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      IconButton(
                        key: const ValueKey<String>('now-playing-next'),
                        iconSize: 30,
                        onPressed: ready
                            ? () => unawaited(widget.onNext())
                            : null,
                        icon: const Icon(Icons.skip_next),
                      ),
                    ],
                  ),
                  Expanded(
                    child: _fadeWhenImmersive(
                      chromeKey: const ValueKey<String>(
                        'now-playing-chrome-extra',
                      ),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Padding(
                          padding: const EdgeInsets.only(left: 24),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: <Widget>[
                              IconButton(
                                key: const ValueKey<String>('now-playing-mode'),
                                tooltip:
                                    '播放模式：${playbackModeLabel(data.repeat, data.shuffle)}',
                                onPressed: ready
                                    ? widget.onCyclePlayMode
                                    : null,
                                icon: Icon(
                                  playbackModeIcon(data.repeat, data.shuffle),
                                  size: 24,
                                  color:
                                      playbackModeActive(
                                        data.repeat,
                                        data.shuffle,
                                      )
                                      ? scheme.primary
                                      : scheme.onSurfaceVariant,
                                ),
                              ),
                              IconButton(
                                key: const ValueKey<String>(
                                  'now-playing-queue',
                                ),
                                tooltip: '播放队列',
                                onPressed: ready ? widget.onShowQueue : null,
                                icon: const Icon(Icons.queue_music, size: 24),
                              ),
                              if (widget.onSelectDevice != null)
                                _OutputDeviceButton(
                                  devices: widget.devices,
                                  selected: widget.selectedDevice,
                                  onSelect: widget.onSelectDevice!,
                                  // 按钮在右上角，提示挂在它下面
                                  onToast: (String message, LayerLink link) =>
                                      _showToast(
                                        message,
                                        link: link,
                                        targetAnchor: Alignment.bottomCenter,
                                        followerAnchor: Alignment.topCenter,
                                        offset: const Offset(0, 12),
                                      ),
                                ),
                              PopupMenuButton<_SleepOption>(
                                key: const ValueKey<String>(
                                  'now-playing-sleep',
                                ),
                                tooltip: _sleepTooltip,
                                padding: EdgeInsets.zero,
                                onSelected: _onSleepSelected,
                                itemBuilder: (BuildContext context) =>
                                    <PopupMenuEntry<_SleepOption>>[
                                      for (final (
                                            _SleepOption option,
                                            String label,
                                          )
                                          in _SleepOption.labels)
                                        PopupMenuItem<_SleepOption>(
                                          value: option,
                                          child: Text(label),
                                        ),
                                    ],
                                icon: Icon(
                                  Icons.bedtime_outlined,
                                  size: 24,
                                  color: _sleepUntil != null
                                      ? scheme.primary
                                      : scheme.onSurfaceVariant,
                                ),
                              ),
                              if (widget.onOpenEqualizer != null)
                                IconButton(
                                  key: const ValueKey<String>(
                                    'now-playing-equalizer',
                                  ),
                                  tooltip: '均衡器',
                                  onPressed: widget.onOpenEqualizer,
                                  icon: const Icon(Icons.equalizer, size: 24),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                data.isAvailable ? '' : '播放引擎不可用',
                style: theme.textTheme.bodySmall?.copyWith(color: scheme.error),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// 输出设备选择：菜单里列「系统默认 + 枚举到的设备」，当前项打勾。
class _OutputDeviceButton extends StatefulWidget {
  const _OutputDeviceButton({
    required this.devices,
    required this.selected,
    required this.onSelect,
    required this.onToast,
  });

  final ValueListenable<List<rust.PlayerDevice>>? devices;
  final ValueListenable<int>? selected;

  /// 选中某块声卡（-1 表示回到系统默认）
  final ValueChanged<int> onSelect;

  /// 弹提示：设备名在菜单里可能被截断，这里补全
  final void Function(String message, LayerLink link) onToast;

  @override
  State<_OutputDeviceButton> createState() => _OutputDeviceButtonState();
}

class _OutputDeviceButtonState extends State<_OutputDeviceButton> {
  /// 提示要挂在这个按钮下面
  final LayerLink _link = LayerLink();

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final ValueListenable<List<rust.PlayerDevice>>? list = widget.devices;
    final ValueListenable<int>? current = widget.selected;
    if (list == null || current == null) {
      return const SizedBox.shrink();
    }
    return ValueListenableBuilder<int>(
      valueListenable: current,
      builder: (BuildContext context, int active, Widget? child) =>
          ValueListenableBuilder<List<rust.PlayerDevice>>(
            valueListenable: list,
            builder:
                (
                  BuildContext context,
                  List<rust.PlayerDevice> available,
                  Widget? child,
                ) {
                  final bool hasDevices = available.isNotEmpty;
                  return PopupMenuButton<int>(
                    key: const ValueKey<String>('now-playing-output'),
                    tooltip: '输出设备',
                    padding: EdgeInsets.zero,
                    enabled: hasDevices,
                    onSelected: (int index) {
                      String name = '系统默认';
                      for (final rust.PlayerDevice device in available) {
                        if (device.index == index) {
                          name = device.name;
                        }
                      }
                      widget.onSelect(index);
                      widget.onToast('输出设备：$name', _link);
                    },
                    itemBuilder: (BuildContext context) =>
                        <PopupMenuEntry<int>>[
                          CheckedPopupMenuItem<int>(
                            value: -1,
                            checked: active < 0,
                            child: const Text('系统默认'),
                          ),
                          for (final rust.PlayerDevice device in available)
                            CheckedPopupMenuItem<int>(
                              value: device.index,
                              checked: device.index == active,
                              child: Text(device.name),
                            ),
                        ],
                    icon: CompositedTransformTarget(
                      link: _link,
                      child: Icon(
                        Icons.speaker_outlined,
                        size: 24,
                        // 选中了具体设备时用主色提示「不是系统默认」
                        color: active >= 0
                            ? scheme.primary
                            : scheme.onSurfaceVariant,
                      ),
                    ),
                  );
                },
          ),
    );
  }
}

/// Sleep timer 的选项
enum _SleepOption {
  minutes15('15 分钟后暂停'),
  minutes30('30 分钟后暂停'),
  minutes45('45 分钟后暂停'),
  minutes60('60 分钟后暂停'),
  endOfTrack('播完当前曲目'),
  cancel('取消定时');

  const _SleepOption(this.label);

  final String label;

  static const List<(_SleepOption, String)> labels = <(_SleepOption, String)>[
    (_SleepOption.minutes15, '15 分钟后暂停'),
    (_SleepOption.minutes30, '30 分钟后暂停'),
    (_SleepOption.minutes45, '45 分钟后暂停'),
    (_SleepOption.minutes60, '60 分钟后暂停'),
    (_SleepOption.endOfTrack, '播完当前曲目'),
    (_SleepOption.cancel, '取消定时'),
  ];
}

/// 进入沉浸模式时的轻提示：淡入 → 停留 → 淡出后自删。
class _ImmersiveToast extends StatefulWidget {
  const _ImmersiveToast({required this.message, required this.onDone});

  final String message;
  final VoidCallback onDone;

  @override
  State<_ImmersiveToast> createState() => _ImmersiveToastState();
}

class _ImmersiveToastState extends State<_ImmersiveToast>
    with SingleTickerProviderStateMixin {
  late final AnimationController _fade = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 180),
  );

  Timer? _hold;

  @override
  void initState() {
    super.initState();
    unawaited(_play());
  }

  Future<void> _play() async {
    await _fade.forward();
    if (!mounted) {
      return;
    }
    // 停留交给 Timer：页面销毁时能取消，不留悬挂的等待
    _hold = Timer(const Duration(milliseconds: 1100), () {
      unawaited(_dismiss());
    });
  }

  Future<void> _dismiss() async {
    await _fade.reverse();
    if (!mounted) {
      return;
    }
    widget.onDone();
  }

  @override
  void dispose() {
    _hold?.cancel();
    _fade.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return IgnorePointer(
      child: FadeTransition(
        opacity: _fade,
        child: Material(
          color: scheme.inverseSurface,
          borderRadius: BorderRadius.circular(20),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
            child: Text(
              widget.message,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: scheme.onInverseSurface,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
