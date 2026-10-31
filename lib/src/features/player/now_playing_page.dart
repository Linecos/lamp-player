import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/immersive_chrome.dart';
import '../../app/title_bar.dart';
import '../../app/window_controls.dart';
import '../../common/formatters/duration.dart';
import '../../common/ui_clock.dart';
import '../../common/widgets/album_cover.dart';
import '../../common/widgets/cover_shape.dart';
import '../../common/widgets/slider_semantics_scope.dart';
import '../../rust/api/lyrics.dart' as lyrics_api;
import '../../rust/api/model.dart';
import '../../rust/api/player.dart' as rust;
import '../../theme/app_theme.dart';
import '../library/library_sort.dart' show trackArtist;
import 'cover_palette.dart';
import 'lyrics_view.dart';
import 'output_device_dialog.dart';
import 'playback_mode.dart';
import 'playback_queue.dart';
import 'shortcuts.dart';
import 'sleep_timer_dialog.dart';
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
    this.desktopLyrics = false,
    this.desktopLyricLocked = false,
  });

  final Track? track;
  final bool isPlaying;
  final double position;
  final double duration;
  final bool isAvailable;
  final double volume;
  final LoopMode repeat;
  final bool shuffle;

  /// 桌面歌词是否打开
  final bool desktopLyrics;

  /// 桌面歌词是否锁定（锁定 = 鼠标穿透）
  final bool desktopLyricLocked;
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
    this.windowControls,
    this.shortcuts = kDefaultShortcuts,
    this.onToggleDesktopLyrics,
    this.onToggleDesktopLyricLock,
    this.onOpenArtist,
    this.onOpenAlbum,
  });

  /// 打开均衡器页；为空时不显示该按钮
  final VoidCallback? onOpenEqualizer;

  /// 点歌手 / 专辑跳到曲库对应分区；为空时那一行退化成普通文本。
  ///
  /// 传整个 [Track] 而不是名字：专辑是按「歌手 + 专辑名」聚合的，
  /// 聚合键怎么算属于曲库那边的规则，不该让本页去复制一份。
  final ValueChanged<Track>? onOpenArtist;
  final ValueChanged<Track>? onOpenAlbum;

  /// 开关桌面歌词；为空时不显示该按钮
  final VoidCallback? onToggleDesktopLyrics;

  /// 锁定 / 解锁桌面歌词（锁定 = 鼠标穿透，桌面上点不到，只能从这里解开）
  final VoidCallback? onToggleDesktopLyricLock;

  /// 频谱数据：传了才在歌词下层铺一条全宽音频丝带
  final ValueListenable<List<double>>? spectrum;

  /// 背景流光开关；默认关闭，生产入口显式开启，测试 / golden 保持静态。
  final bool animateBackground;

  /// 窗口控制（拖动 / 双击最大化）：页面盖住了外壳的标题栏，
  /// 这一层得自带拖动区，否则正在播放页上按不住窗口
  final WindowControls? windowControls;

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

  /// 宽屏内容的最大宽度：再宽就不跟着长，整块居中，避免超宽屏上左右拉散
  static const double _maxContentWidth = 1600;

  /// 顶部那一条「正在播放 + 收起」的高度：封面要按**窗口**上边界对齐，
  /// 而 `_body` 的坐标原点在 header 下面，算等距时得把它减掉
  static const double _headerHeight = 48;

  /// 45 度线上的最小内边距占窗口短边的比例：小窗口靠它离开角落
  static const double _minInsetRatio = 0.22;

  /// 封面上方那几行（歌名 / 歌手-专辑）大致占的高度：算封面能长多大时要
  /// 把它一起留出来，免得整列顶到频谱丝带上
  static const double _infoReserve = 104;

  /// 封面上面信息块 + 间距的实际高度：歌词当前行要和封面中心线对齐，按它换算。
  /// 比 [_infoReserve] 略小，那 8px 是留给尺寸预算的余量
  static const double _infoBlockHeight = 96;

  /// 专辑并入歌手行后空出的一行（2px 间距 + 17px 行高）：标题下移补位，
  /// 封面不跟着上移
  static const double _infoRefillHeight = 19;

  /// 信息块挪到封面上方后整列上提的量：不提的话封面会整体矮下去 96，
  /// 视觉重心掉到窗口中部；提一半刚好回到原来的位置感
  static const double _infoBlockLift = 48;

  /// 封面外圈留给阴影的余量（blur 28 + 偏移 10/12 + 呼吸空间），左右各一半
  static const double _coverShadowPad = 84;

  /// 封面最小边长：再矮的窗口也不缩到看不清楚
  static const double _minCoverSize = 200;

  /// 频谱丝带：贴底 [_spectrumBottom]、高 [_spectrumHeight]。
  /// 歌词的底部淡出要盖过这条丝带，两处数值必须同源。
  static const double _spectrumBottom = 6;
  static const double _spectrumHeight = 72;

  /// 圆形封面转一圈的时间（唱片机那种缓慢匀速）
  static const Duration _coverSpinPeriod = Duration(seconds: 25);

  lyrics_api.TrackLyrics? _lyrics;
  String? _loadedPath;
  bool _loading = false;

  /// 当前封面的取色结果；为空时背景用主题色兜底。
  List<Color>? _palette;

  /// 当前路由的转场动画：收起时据此把窗口按钮交还给全局那层
  Animation<double>? _routeAnimation;

  /// 播放进度（秒）：歌词视图拿它做插值，拖动预览不碰它。
  final ValueNotifier<double> _position = ValueNotifier<double>(0);

  /// 当前曲目：只在切歌 / 曲目对象刷新时通知。
  ///
  /// 进度 tick 不碰它，所以歌词列表与封面不会每 500ms 重新布局。
  final ValueNotifier<Track?> _track = ValueNotifier<Track?>(null);

  /// 播放 / 暂停：只驱动封面的跳动图标，范围比整页小得多。
  final ValueNotifier<bool> _playing = ValueNotifier<bool>(false);

  /// 圆形封面的旋转角度（0~1 圈）：只在「圆形封面 + 正在播放」时转，
  /// 暂停停在当前角度。用 [UiClock.fast]（60fps）推进：旋转是最吃时间分辨率的
  /// 动作，15fps 一眼看出停顿、30fps 仍略跳；跟着显示器刷新率走的话，240Hz 屏上
  /// 等于每帧重新旋转、重新贴图。
  final ValueNotifier<double> _coverTurns = ValueNotifier<double>(0);

  /// 暂停前累计转过的秒数 / 本次开始转的时刻（[UiClock] 秒）
  double _spinElapsed = 0;
  double _spinStartedAt = 0;
  bool _spinning = false;

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

  /// 本轮定时是否已经为「听完当前曲目」顺延过一次
  bool _sleepExtended = false;

  /// 到点时若本曲没播完，是否顺延到播完（浮窗里的开关，默认开）
  bool _sleepExtendToTrackEnd = true;

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
    return _sleepExtended ? '睡眠定时：播完当前曲目后暂停' : '睡眠定时：还剩 $minutes 分钟';
  }

  /// 打开睡眠定时浮窗：时钟轮盘选 0~60 分钟
  Future<void> _openSleepTimer() async {
    final DateTime? until = _sleepUntil;
    final int? remaining = until == null
        ? null
        : (until.difference(DateTime.now()).inSeconds / 60).ceil().clamp(1, 60);
    final SleepTimerResult? choice = await showSleepTimerDialog(
      context,
      initialMinutes: remaining ?? 30,
      hasTimer: until != null,
      extendToTrackEnd: _sleepExtendToTrackEnd,
    );
    if (choice == null || !mounted) {
      return;
    }
    final int minutes = choice.minutes;
    _sleepExtendToTrackEnd = choice.extendToTrackEnd;
    _sleepTimer?.cancel();
    _sleepTimer = null;
    // 重新设定后允许再顺延一次
    _sleepExtended = false;
    if (minutes <= 0) {
      setState(() => _sleepUntil = null);
      return;
    }
    _armSleep(Duration(minutes: minutes));
  }

  void _armSleep(Duration delay) {
    _sleepTimer?.cancel();
    _sleepTimer = Timer(delay, _fireSleep);
    setState(() => _sleepUntil = DateTime.now().add(delay));
  }

  /// 到点：正在播就暂停（不停止，醒来点一下就能接着听）。
  ///
  /// 当前曲目还没播完就不掐：先把这首听完再暂停，只顺延一次——顺延到点后
  /// 哪怕用户又拖回前段也直接暂停，免得变成永远不睡。
  void _fireSleep() {
    _sleepTimer = null;
    if (!mounted) {
      return;
    }
    // 时长取播放器上报的值（data.duration），不是标签里的 durationSecs：
    // 后者可能还没解析出来，会让顺延判断失效
    final double duration = widget.data.value.duration;
    final double left = duration - _position.value;
    if (_sleepExtendToTrackEnd &&
        !_sleepExtended &&
        widget.data.value.isPlaying &&
        duration > 0 &&
        left > 1) {
      _sleepExtended = true;
      final Duration rest = Duration(milliseconds: (left * 1000).round() + 200);
      _sleepTimer = Timer(rest, _fireSleep);
      setState(() => _sleepUntil = DateTime.now().add(rest));
      return;
    }
    _sleepExtended = false;
    setState(() => _sleepUntil = null);
    if (widget.data.value.isPlaying) {
      unawaited(widget.onTogglePlay());
    }
    _showToast('睡眠定时已到，已暂停播放');
  }

  /// 按住头部拖动窗口（页面自绘标题栏，外壳那一层被路由盖住了）
  Future<void> _startDragging() async {
    try {
      await widget.windowControls?.startDragging();
    } catch (error) {
      debugPrint('拖动窗口失败：$error');
    }
  }

  /// 双击头部最大化 / 还原，与外壳标题栏一致
  Future<void> _toggleWindowMaximize() async {
    try {
      await widget.windowControls?.toggleMaximize();
    } catch (error) {
      debugPrint('切换最大化失败：$error');
    }
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

  /// 轻提示统一弹在播放 / 暂停键上方：那位置在窗口里是水平的中间，
  /// 无论提示来自哪个按钮都出现在同一处，不会跟着按钮跑到屏幕边缘。
  void _showToast(String message) {
    _removeToast();
    final OverlayState? overlay = Overlay.maybeOf(context);
    if (overlay == null) {
      return;
    }
    final OverlayEntry entry = OverlayEntry(
      builder: (BuildContext context) => Positioned(
        left: 0,
        top: 0,
        child: CompositedTransformFollower(
          link: _toggleLink,
          showWhenUnlinked: false,
          targetAnchor: Alignment.topCenter,
          followerAnchor: Alignment.bottomCenter,
          offset: const Offset(0, -14),
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
    circularCovers.addListener(_syncCoverSpin);
    _onData();
    _publishOwnChrome();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final Animation<double>? animation = ModalRoute.of(context)?.animation;
    if (identical(animation, _routeAnimation)) {
      return;
    }
    _routeAnimation?.removeStatusListener(_onRouteStatus);
    _routeAnimation = animation;
    _routeAnimation?.addStatusListener(_onRouteStatus);
  }

  /// 收起动画一开始就把窗口按钮交还给全局那层。
  ///
  /// 等页面 `dispose` 再交还就晚了：页面滑走的这 240ms 里，自己的按钮跟着
  /// 页面往下走了、全局的却还没回来，右上角会空出一块，看起来像「收起后要
  /// 愣一下，按钮才冒出来」。
  void _onRouteStatus(AnimationStatus status) {
    if (status == AnimationStatus.reverse) {
      pageOwnsWindowControls.value = false;
    }
  }

  /// 本页自己画窗口按钮，让全局那层让位——否则两套按钮会同时挂在右上角，
  /// 而且全局那套在转场里纹丝不动，和滑上来的页面脱节。
  void _publishOwnChrome() {
    // 页面要一起滑进来，按钮得跟页面同层，不能用窗口外壳那层浮层
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        pageOwnsWindowControls.value = true;
      }
    });
  }

  @override
  void dispose() {
    _routeAnimation?.removeStatusListener(_onRouteStatus);
    pageOwnsWindowControls.value = false;
    widget.data.removeListener(_onData);
    circularCovers.removeListener(_syncCoverSpin);
    _stopSpin();
    _coverTurns.dispose();
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
      _syncCoverSpin();
    }
    if (_position.value != data.position) {
      _position.value = data.position;
    }
    _syncTrack();
    // 进度与播放态由各自的 builder 局部刷新。
    // 这里不再 setState：每 500ms 整页重建会让歌词列表跟着重新布局。
  }

  /// 圆形封面转不转：只有「圆形封面 + 正在播放」才转，暂停停在当前角度。
  ///
  /// 暂停时把已转的秒数累计下来，再播能接着原来的角度转，不会跳回正面。
  /// 关掉圆形封面时角度归零，下次打开从正面开始。
  void _syncCoverSpin() {
    if (!circularCovers.value) {
      _stopSpin();
      _spinElapsed = 0;
      _coverTurns.value = 0;
      return;
    }
    if (_playing.value) {
      if (!_spinning) {
        _spinning = true;
        _spinStartedAt = UiClock.fast.seconds;
        UiClock.fast.addListener(_onSpinTick);
      }
    } else {
      _stopSpin();
    }
  }

  void _stopSpin() {
    if (!_spinning) {
      return;
    }
    _spinElapsed += UiClock.fast.seconds - _spinStartedAt;
    _spinning = false;
    UiClock.fast.removeListener(_onSpinTick);
  }

  void _onSpinTick() {
    final double seconds = _spinElapsed + UiClock.fast.seconds - _spinStartedAt;
    _coverTurns.value =
        (seconds / (_coverSpinPeriod.inMilliseconds / 1000)) % 1;
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
    // 色板先留着上一首的：清空会让整屏背景先闪一下主题色、等新色板算好
    // （几十毫秒后）再跳回来，等于切一次歌变两次色。旧的留在原地，新色板
    // 到了由背景自己做淡入。
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
                              bottom: _spectrumBottom,
                              height: _spectrumHeight,
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
    return Padding(
      key: const ValueKey<String>('now-playing-header'),
      // 贴住窗口顶端，中心 y≈24；右边不留白，让三个按钮和全局那层的位置
      // 逐像素对齐，转场时看着是「同一组按钮跟着页面走」
      padding: const EdgeInsets.only(left: 8),
      child: SizedBox(
        height: 48,
        child: AnimatedBuilder(
          animation: Listenable.merge(<Listenable>[
            immersiveMode,
            pointerNearTop,
          ]),
          // 沉浸模式下只保留封面 / 歌名 / 歌词，返回键靠指针靠近顶端唤出
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
              // 热区只覆盖箭头周围这一圈。
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
              // 按钮右边的整条留白就是拖动区：正在播放页是整窗路由，把外壳
              // 标题栏连同它的拖动区一起盖住了，不在这里补一个，窗口就拖不动。
              // 拖动区必须和按钮并列而不是把它包进去——包进去的话，外层带了
              // 双击手势，单击会被拖到 300ms 的双击判定之后才落地，按钮变迟钝。
              Expanded(
                child: GestureDetector(
                  key: const ValueKey<String>('now-playing-window-drag'),
                  behavior: HitTestBehavior.opaque,
                  onPanStart: (_) => unawaited(_startDragging()),
                  onDoubleTap: () => unawaited(_toggleWindowMaximize()),
                  child: const SizedBox.expand(),
                ),
              ),
              // 本页自己画窗口按钮：跟着页面一起滑进来 / 滑出去。背景是封面
              // 取色的渐变，固定用白色字形 + 描影，任何封面上都读得出来。
              if (widget.windowControls != null)
                WindowButtons(
                  controls: widget.windowControls!,
                  foreground: Colors.white,
                  castShadow: true,
                ),
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
        // 内容宽度跟着窗口走（上限 1600，再宽就整块居中），封面尺寸则由宽度、
        // 高度两个预算取小——否则要么全屏时封面贴在左边、歌词甩到右边，
        // 要么矮窗口里封面 + 下方三行文字顶到频谱丝带上。
        final double contentWidth = math.min(
          constraints.maxWidth - 64,
          _maxContentWidth,
        );
        // 封面到**窗口**左边界的距离：页面内边距 32 + 内容块限宽后居中的偏移
        // + 封面外圈留给阴影的余量
        final double centerGap =
            math.max(0, constraints.maxWidth - 64 - contentWidth) / 2;
        final double baseInset = centerGap + 32 + _coverShadowPad / 2;
        // 74 太贴左上角（封面本身才 300 出头，离边太近会显得挤在角落），
        // 按可用短边的 22% 起算；大窗口本来就更靠内，取两者较大的那个。
        final double coverInset = math.max(
          baseInset,
          math.min(constraints.maxWidth, constraints.maxHeight) *
              _minInsetRatio,
        );
        // 封面尺寸：宽度允许的上限（左栏占内容宽 35%）和「实际还剩多少高度」
        // 二选一，取小的。默认 1280×720 窗口下封面原本 342，加上下方三行文字
        // 就顶到频谱丝带上了——不放小就再也挪不进去，只能一直贴在左上角。
        final double areaHeight =
            constraints.maxHeight - _spectrumBottom - _spectrumHeight;
        final double widthBudget =
            (contentWidth * 0.35).clamp(380.0, 560.0) - _coverShadowPad;
        final double heightBudget =
            areaHeight + _headerHeight - _infoReserve - coverInset;
        final double coverSize = math
            .min(widthBudget, heightBudget)
            .clamp(_minCoverSize, 440.0);
        // 左栏宽度跟着封面走，封面在栏内水平居中（左右各留半个阴影余量）
        final double laneWidth = coverSize + _coverShadowPad;
        // 多出来的量左右各让一半：内容块整体内缩，封面左边距正好等于 coverInset
        final double extraInset = coverInset - baseInset;
        // `_body` 从 header 下方开始，换算成窗口坐标要减掉 header 的高度，
        // 否则封面看起来离顶还是比离左更远一截；信息块占了封面上面一截，
        // 再把整列上提 [_infoBlockLift]
        final double topPadding = math.max(
          8,
          coverInset - _headerHeight - _infoBlockLift,
        );
        // 歌词当前行与封面中心线对齐：封面中心在信息行下面，换算成歌词视口的比例
        final double lyricHeight = math.max(
          1,
          constraints.maxHeight - topPadding,
        );
        final double revealAlignment =
            ((_infoBlockHeight + coverSize / 2) / lyricHeight).clamp(
              0.35,
              0.68,
            );
        final Widget info = _trackInfo(context, track, wide ? coverSize : 240);
        final Widget lyric = _lyricsView(
          context,
          revealAlignment: wide ? revealAlignment : 0.5,
        );
        if (wide) {
          return Padding(
            padding: EdgeInsets.fromLTRB(32, topPadding, 32, 0),
            child: Align(
              alignment: Alignment.topCenter,
              child: SizedBox(
                // 位置靠「内缩 contentWidth + 居中」实现，左右各让 extraInset
                width: math.max(0, contentWidth - extraInset * 2),
                // 顶部内边距已吃掉 topPadding；Row 是 stretch，需要确定高度
                height: math.max(0, constraints.maxHeight - topPadding),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    SizedBox(
                      width: laneWidth,
                      // 水平居中（阴影有余量）、垂直靠顶：封面顶边就是内边距
                      child: Align(
                        alignment: Alignment.topCenter,
                        child: SizedBox(width: coverSize, child: info),
                      ),
                    ),
                    const SizedBox(width: 32),
                    Expanded(child: lyric),
                  ],
                ),
              ),
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

  /// 「歌手-专辑」一行：两段各自可点，分别跳曲库的艺术家 / 专辑详情。
  ///
  /// 分隔符与字号沿用原来那条合成文本，所以看起来和之前一模一样，
  /// 只是鼠标移上去会变主题色加下划线——不这样根本看不出它能点。
  Widget _metaLine(BuildContext context, Track track) {
    final ThemeData theme = Theme.of(context);
    final TextStyle style = (theme.textTheme.bodyLarge ?? const TextStyle())
        .copyWith(color: theme.colorScheme.onSurfaceVariant);
    final String album = (track.album ?? '').trim();
    final ValueChanged<Track>? openArtist = widget.onOpenArtist;
    final ValueChanged<Track>? openAlbum = widget.onOpenAlbum;

    return Row(
      key: const ValueKey<String>('now-playing-meta'),
      // 必须按内容收缩：Row 撑满整宽会把这一列一起撑宽，窄窗口里封面
      // 会跟着横移半个屏（布局 golden 上直接能看出来）
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Flexible(
          child: _MetaLink(
            key: const ValueKey<String>('now-playing-artist'),
            text: trackArtist(track),
            style: style,
            tooltip: '查看艺术家',
            onTap: openArtist == null ? null : () => openArtist(track),
          ),
        ),
        if (album.isNotEmpty) ...<Widget>[
          Text('-', style: style),
          Flexible(
            child: _MetaLink(
              key: const ValueKey<String>('now-playing-album'),
              text: album,
              style: style,
              tooltip: '查看专辑',
              onTap: openAlbum == null ? null : () => openAlbum(track),
            ),
          ),
        ],
      ],
    );
  }

  Widget _trackInfo(BuildContext context, Track track, double coverSize) {
    final ThemeData theme = Theme.of(context);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        // 曲目信息压在封面上面（对齐参考布局）：先读完「在放什么」，再往下看封面
        Column(
          key: const ValueKey<String>('now-playing-info'),
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            // 专辑并入歌手行后少了一行：标题下移补位，封面位置不跟着上移
            const SizedBox(height: _infoRefillHeight),
            Text(
              track.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            _metaLine(context, track),
          ],
        ),
        const SizedBox(height: 16),
        // 剩下的高度都给封面：放不下就自己缩，别把整列顶出可视区
        // （900×560 这种最小窗口）。只缩封面不缩文字，文字保持原生字号不发虚。
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
                  // 大封面本体：Hero 子树与飞行 shuttle 共用同一份配置。
                  // 收起时的目标在播放条，那边只有 56px 的小图，默认 shuttle
                  // 会拿它放大，动画一开始就糊成一片；统一用这张大图，正反
                  // 两个方向都清楚，形状也始终一致。
                  final Widget cover = AlbumCover(
                    path: track.coverPath,
                    size: size,
                    // 外层阴影容器的圆角必须与封面一致，否则角上会露一圈光晕
                    radius: 28,
                    playing: playing,
                    // 换歌时新封面收进来 + 淡入，别硬切
                    animateOnChange: true,
                  );
                  // 阴影必须挂在 Hero **里面**：留在外面时封面飞走了、那圈黑影
                  // 还杵在原地，收起过程中就是一团孤零零的暗斑跟着背景慢慢淡出
                  Widget withShadow(Widget inner) {
                    return ValueListenableBuilder<bool>(
                      valueListenable: circularCovers,
                      builder:
                          (BuildContext context, bool circular, Widget? child) {
                            return Container(
                              decoration: BoxDecoration(
                                // 圆形封面时阴影容器也要跟着圆：矩形阴影会在
                                // 圆角外露出一圈方形的光晕
                                shape: circular
                                    ? BoxShape.circle
                                    : BoxShape.rectangle,
                                // 与卡片同级：336px 的大封面用 20 显得几乎是直角
                                borderRadius: circular
                                    ? null
                                    : BorderRadius.circular(28),
                                boxShadow: <BoxShadow>[
                                  BoxShadow(
                                    color: Colors.black.withValues(alpha: 0.35),
                                    blurRadius: 28,
                                    spreadRadius: 2,
                                    offset: const Offset(10, 12),
                                  ),
                                ],
                              ),
                              child: child,
                            );
                          },
                      child: inner,
                    );
                  }

                  return Hero(
                    tag: coverHeroTag,
                    createRectTween: (Rect? begin, Rect? end) =>
                        RectTween(begin: begin, end: end),
                    // 正反两个方向都用播放页这张大图：收起时的目标在播放条，
                    // 那边只有 56px 小图，默认 shuttle 拿它放大时一路发虚。
                    //
                    // 但**不要**带阴影：飞行中矩形的尺寸每帧都在变，
                    // `blurRadius: 28` 的 boxShadow 等于每帧按新尺寸重做一遍
                    // 高斯模糊，是转场掉帧最大的一笔开销。阴影留在页面里的
                    // Hero 子树上（不飞行时是一次性栅格化）。
                    //
                    // 布局尺寸也固定成大图、靠 `FittedBox` 缩放：shuttle 拿到的是
                    // 每帧都变的紧约束，直接铺进去等于每帧按新尺寸重新栅格化
                    // 整张封面；固定尺寸后每帧只改一个缩放矩阵，纹理直接复用。
                    flightShuttleBuilder:
                        (
                          BuildContext flightContext,
                          Animation<double> animation,
                          HeroFlightDirection direction,
                          BuildContext fromHeroContext,
                          BuildContext toHeroContext,
                        ) => FittedBox(
                          fit: BoxFit.fill,
                          child: SizedBox(
                            width: size,
                            height: size,
                            child: RepaintBoundary(child: cover),
                          ),
                        ),
                    child: withShadow(
                      // 旋转用「Transform 在上、RepaintBoundary 在下」：
                      // Transform 才会被提升成图层矩阵（只改矩阵、复用下面的
                      // 光栅），反过来套一层边界就每帧重新光栅化一遍
                      ValueListenableBuilder<double>(
                        valueListenable: _coverTurns,
                        // 25s 一圈：只在圆形封面 + 播放中才转（见 _syncCoverSpin）
                        builder:
                            (
                              BuildContext context,
                              double turns,
                              Widget? child,
                            ) => Transform.rotate(
                              key: const ValueKey<String>(
                                'now-playing-cover-spin',
                              ),
                              angle: turns * math.pi * 2,
                              child: child,
                            ),
                        // 封面自己一层：转起来只动矩阵，不重画歌词 / 控件
                        child: RepaintBoundary(child: cover),
                      ),
                    ),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _lyricsView(BuildContext context, {double revealAlignment = 0.5}) {
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
      // 频谱丝带铺在歌词下层：底部要淡干净这一段，滚下来的文字才不会压在柱子上
      edgeFadeBand: widget.spectrum == null
          ? 0
          : _spectrumBottom + _spectrumHeight,
      revealAlignment: revealAlignment,
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
                                  onToast: _showToast,
                                ),
                              IconButton(
                                key: const ValueKey<String>(
                                  'now-playing-sleep',
                                ),
                                tooltip: _sleepTooltip,
                                padding: EdgeInsets.zero,
                                // 秒表比月亮更能表达「倒计时到点暂停」
                                onPressed: () => unawaited(_openSleepTimer()),
                                icon: Icon(
                                  Icons.timer_outlined,
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
                              if (widget.onToggleDesktopLyrics != null)
                                IconButton(
                                  key: const ValueKey<String>(
                                    'now-playing-desktop-lyrics',
                                  ),
                                  tooltip: data.desktopLyrics
                                      ? '关闭桌面歌词'
                                      : '桌面歌词',
                                  onPressed: widget.onToggleDesktopLyrics,
                                  icon: Icon(
                                    data.desktopLyrics
                                        ? Icons.subtitles
                                        : Icons.subtitles_outlined,
                                    size: 24,
                                    color: data.desktopLyrics
                                        ? scheme.primary
                                        : scheme.onSurfaceVariant,
                                  ),
                                ),
                              // 锁定后桌面歌词窗口鼠标穿透，点不到也拖不动，
                              // 这个开关是唯一的解锁入口，所以常驻在歌词按钮旁边
                              if (widget.onToggleDesktopLyricLock != null &&
                                  data.desktopLyrics)
                                IconButton(
                                  key: const ValueKey<String>(
                                    'now-playing-desktop-lyrics-lock',
                                  ),
                                  tooltip: data.desktopLyricLocked
                                      ? '解锁桌面歌词'
                                      : '锁定桌面歌词（鼠标穿透）',
                                  onPressed: widget.onToggleDesktopLyricLock,
                                  icon: Icon(
                                    data.desktopLyricLocked
                                        ? Icons.lock
                                        : Icons.lock_open,
                                    size: 24,
                                    color: data.desktopLyricLocked
                                        ? scheme.primary
                                        : scheme.onSurfaceVariant,
                                  ),
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

/// 输出设备按钮：点开弹窗列「系统默认 + 枚举到的设备」，当前项打勾。
/// 曲目信息行里的可点文字（歌手 / 专辑）。
///
/// 悬停时变主题色 + 下划线、光标变手型；[onTap] 为空时退化成普通文本，
/// 排版完全一致——能点与不能点只在鼠标移上去时才该有区别。
class _MetaLink extends StatefulWidget {
  const _MetaLink({
    super.key,
    required this.text,
    required this.style,
    this.tooltip,
    this.onTap,
  });

  final String text;
  final TextStyle style;
  final String? tooltip;
  final VoidCallback? onTap;

  @override
  State<_MetaLink> createState() => _MetaLinkState();
}

class _MetaLinkState extends State<_MetaLink> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final Color accent = Theme.of(context).colorScheme.primary;
    final bool enabled = widget.onTap != null;
    final Widget label = Text(
      widget.text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: _hovered && enabled
          ? widget.style.copyWith(
              color: accent,
              decoration: TextDecoration.underline,
              decorationColor: accent,
            )
          : widget.style,
    );
    if (!enabled) {
      return label;
    }
    final Widget link = MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (PointerEnterEvent _) => setState(() => _hovered = true),
      onExit: (PointerExitEvent _) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: label,
      ),
    );
    final String? tooltip = widget.tooltip;
    return tooltip == null
        ? link
        : Tooltip(
            message: tooltip,
            waitDuration: const Duration(milliseconds: 600),
            child: link,
          );
  }
}

class _OutputDeviceButton extends StatelessWidget {
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

  /// 选完弹一句提示（位置由页面统一决定）
  final ValueChanged<String> onToast;

  /// 打开设备弹窗；选中后回调给页面并提示一句
  Future<void> _pick(
    BuildContext context,
    List<rust.PlayerDevice> available,
    int active,
  ) async {
    final int? picked = await showOutputDeviceDialog(
      context,
      devices: available,
      selected: active,
    );
    if (picked == null) {
      return;
    }
    String name = '系统默认';
    for (final rust.PlayerDevice device in available) {
      if (device.index == picked) {
        name = device.name;
      }
    }
    onSelect(picked);
    onToast('输出设备：$name');
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final ValueListenable<List<rust.PlayerDevice>>? list = devices;
    final ValueListenable<int>? current = selected;
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
                  return IconButton(
                    key: const ValueKey<String>('now-playing-output'),
                    tooltip: '输出设备',
                    padding: EdgeInsets.zero,
                    onPressed: hasDevices
                        ? () => unawaited(_pick(context, available, active))
                        : null,
                    icon: Icon(
                      Icons.speaker_outlined,
                      size: 24,
                      // 选中了具体设备时用主色提示「不是系统默认」
                      color: active >= 0
                          ? scheme.primary
                          : scheme.onSurfaceVariant,
                    ),
                  );
                },
          ),
    );
  }
}

/// Sleep timer 的选项

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
