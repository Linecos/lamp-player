import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../rust/api/lyrics.dart' as lyrics_api;

/// 歌词视图：居中、当前行逐字染色、上下淡出。
///
/// 进度只从 [position] 拿（播放服务每 500ms 推一次），行内用 [Ticker] 插值到
/// 每帧，逐字染色才不会一顿一顿。整列歌词一次性建好（一首歌通常 < 200 行），
/// 换来的是变高行也能精确居中——虚拟列表做不到这一点。
class LyricsView extends StatefulWidget {
  const LyricsView({
    super.key,
    required this.lines,
    required this.position,
    required this.playing,
    required this.onSeek,
  });

  final List<lyrics_api.LyricLine> lines;

  /// 播放进度（秒）
  final ValueListenable<double> position;

  /// 是否正在播放：暂停时停止插值，避免歌词继续走
  final ValueListenable<bool> playing;

  final Future<void> Function(double seconds) onSeek;

  @override
  State<LyricsView> createState() => _LyricsViewState();
}

class _LyricsViewState extends State<LyricsView>
    with SingleTickerProviderStateMixin {
  final ScrollController _scroll = ScrollController();

  /// 插值后的进度：每帧更新，只被当前行监听
  final ValueNotifier<double> _smooth = ValueNotifier<double>(0);

  final Stopwatch _watch = Stopwatch();
  late final Ticker _ticker;

  late List<GlobalKey> _keys;

  double _base = 0;
  int _active = -1;
  bool _playing = false;
  bool _userScrolling = false;
  Timer? _resumeTimer;

  @override
  void initState() {
    super.initState();
    _keys = _buildKeys();
    _ticker = createTicker(_onTick);
    _base = widget.position.value;
    _smooth.value = _base;
    _active = _indexAt(_base);
    _playing = widget.playing.value;
    widget.position.addListener(_onPosition);
    widget.playing.addListener(_onPlaying);
    _syncTicker();
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _scrollToActive(animate: false),
    );
  }

  @override
  void didUpdateWidget(LyricsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.lines, widget.lines)) {
      _keys = _buildKeys();
      _active = -1;
      _smooth.value = _base;
      _active = _indexAt(_base);
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _scrollToActive(animate: false),
      );
    }
    if (oldWidget.position != widget.position) {
      oldWidget.position.removeListener(_onPosition);
      widget.position.addListener(_onPosition);
      _onPosition();
    }
    if (oldWidget.playing != widget.playing) {
      oldWidget.playing.removeListener(_onPlaying);
      widget.playing.addListener(_onPlaying);
      _onPlaying();
    }
  }

  @override
  void dispose() {
    widget.position.removeListener(_onPosition);
    widget.playing.removeListener(_onPlaying);
    _resumeTimer?.cancel();
    _ticker.dispose();
    _scroll.dispose();
    _smooth.dispose();
    super.dispose();
  }

  List<GlobalKey> _buildKeys() =>
      List<GlobalKey>.generate(widget.lines.length, (_) => GlobalKey());

  /// 只有存在逐字时间轴时才需要 60fps 插值；整篇行级歌词跟着 500ms 的进度走就够
  bool get _needsSmoothing =>
      widget.lines.any((lyrics_api.LyricLine line) => line.words.length >= 2);

  void _syncTicker() {
    if (_playing && _needsSmoothing) {
      if (!_ticker.isActive) {
        _watch
          ..reset()
          ..start();
        _ticker.start();
      }
    } else {
      if (_ticker.isActive) {
        _ticker.stop();
      }
      _watch.stop();
    }
  }

  void _onTick(Duration _) {
    _smooth.value = _base + _watch.elapsedMicroseconds / 1000000;
    _updateActive();
  }

  void _onPosition() {
    _base = widget.position.value;
    _watch.reset();
    if (_playing) {
      _watch.start();
    }
    _smooth.value = _base;
    _updateActive();
  }

  void _onPlaying() {
    _playing = widget.playing.value;
    // 暂停瞬间以插值结果为准，避免回跳到 500ms 前的旧进度
    _base = _smooth.value;
    _watch.reset();
    _syncTicker();
  }

  void _updateActive() {
    final int next = _indexAt(_smooth.value);
    if (next == _active) {
      return;
    }
    setState(() => _active = next);
    if (!_userScrolling) {
      _scrollToActive();
    }
  }

  /// 二分找最后一条 `time <= position` 的歌词
  int _indexAt(double seconds) => lyricIndexAt(widget.lines, seconds);

  void _scrollToActive({bool animate = true}) {
    if (_active < 0 || _active >= _keys.length) {
      return;
    }
    final BuildContext? context = _keys[_active].currentContext;
    if (context == null) {
      return;
    }
    unawaited(
      Scrollable.ensureVisible(
        context,
        alignment: 0.5,
        duration: animate ? const Duration(milliseconds: 420) : Duration.zero,
        curve: Curves.easeOutCubic,
      ),
    );
  }

  bool _onScrollNotification(ScrollNotification notification) {
    if (notification is ScrollStartNotification &&
        notification.dragDetails != null) {
      // 用户接管滚动：先别抢，停手 3 秒后再跟回当前行
      _userScrolling = true;
      _resumeTimer?.cancel();
    } else if (notification is ScrollEndNotification && _userScrolling) {
      _resumeTimer?.cancel();
      _resumeTimer = Timer(const Duration(seconds: 3), () {
        if (!mounted) {
          return;
        }
        _userScrolling = false;
        _scrollToActive();
      });
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        // 上下留出半屏，首尾行也能滚到正中间
        final double padding = math.max(24, constraints.maxHeight * 0.4);
        return ShaderMask(
          blendMode: BlendMode.dstIn,
          shaderCallback: (Rect rect) => const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: <Color>[
              Color(0x00FFFFFF),
              Color(0xFFFFFFFF),
              Color(0xFFFFFFFF),
              Color(0x00FFFFFF),
            ],
            stops: <double>[0, 0.12, 0.88, 1],
          ).createShader(rect),
          child: NotificationListener<ScrollNotification>(
            onNotification: _onScrollNotification,
            child: SingleChildScrollView(
              controller: _scroll,
              padding: EdgeInsets.symmetric(vertical: padding, horizontal: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  for (int i = 0; i < widget.lines.length; i += 1)
                    KeyedSubtree(
                      key: ValueKey<String>('lyric-$i'),
                      child: _LyricLineView(
                        anchorKey: _keys[i],
                        line: widget.lines[i],
                        active: i == _active,
                        distance: _active < 0 ? i : (i - _active).abs(),
                        position: _smooth,
                        scheme: scheme,
                        textTheme: theme.textTheme,
                        onSeek: widget.onSeek,
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 二分找最后一条 `time <= seconds` 的歌词下标；没有歌词返回 -1。
///
/// 正在播放页（多行视图）与播放条（单行预览）共用，避免两处各写一份二分。
int lyricIndexAt(List<lyrics_api.LyricLine> lines, double seconds) {
  if (lines.isEmpty) {
    return -1;
  }
  final int ms = (seconds * 1000).round();
  int low = 0;
  int high = lines.length - 1;
  int found = -1;
  while (low <= high) {
    final int mid = (low + high) >> 1;
    if (lines[mid].timeMs.toInt() <= ms) {
      found = mid;
      low = mid + 1;
    } else {
      high = mid - 1;
    }
  }
  return found;
}

/// 单行歌词：正文 +（罗马音 / 翻译）
class _LyricLineView extends StatelessWidget {
  const _LyricLineView({
    required this.anchorKey,
    required this.line,
    required this.active,
    required this.distance,
    required this.position,
    required this.scheme,
    required this.textTheme,
    required this.onSeek,
  });

  /// 滚动居中的锚点：挂在正文上，译文不会把当前行顶偏
  final GlobalKey anchorKey;
  final lyrics_api.LyricLine line;
  final bool active;

  /// 与当前行的距离：用来做由近及远的透明度衰减
  final int distance;
  final ValueListenable<double> position;
  final ColorScheme scheme;
  final TextTheme textTheme;
  final Future<void> Function(double seconds) onSeek;

  @override
  Widget build(BuildContext context) {
    final bool interlude = line.text.trim().isEmpty;
    final TextStyle style = (textTheme.bodyLarge ?? const TextStyle()).copyWith(
      fontSize: active ? 21 : 17,
      height: 1.45,
      fontWeight: active ? FontWeight.w600 : FontWeight.w400,
      letterSpacing: 0.2,
    );

    final Color dim = scheme.onSurfaceVariant.withValues(
      alpha: switch (distance) {
        0 => 0.62,
        1 => 0.48,
        2 => 0.3,
        _ => 0.18,
      },
    );

    final Widget main;
    if (interlude) {
      main = Text(
        '♪',
        textAlign: TextAlign.center,
        style: style.copyWith(
          color: active ? scheme.primary : dim,
          fontSize: active ? 18 : 15,
        ),
      );
    } else if (active && line.words.length >= 2) {
      main = _KaraokeText(
        text: line.text,
        words: line.words,
        lineEndMs: line.endMs.toInt(),
        position: position,
        style: style,
        baseColor: dim,
        highlightColor: scheme.primary,
      );
    } else {
      main = Text(
        line.text,
        textAlign: TextAlign.center,
        style: style.copyWith(color: active ? scheme.primary : dim),
      );
    }

    final List<String> extras = line.translation
        .split('\n')
        .map((String value) => value.trim())
        .where((String value) => value.isNotEmpty)
        .toList();

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => unawaited(onSeek(line.timeMs.toInt() / 1000)),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            KeyedSubtree(key: anchorKey, child: main),
            if (extras.isNotEmpty) const SizedBox(height: 3),
            for (final String extra in extras)
              Padding(
                padding: const EdgeInsets.only(top: 1),
                child: Text(
                  extra,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: _hasCjk(extra) ? 13.5 : 12.5,
                    height: 1.4,
                    color: scheme.onSurfaceVariant.withValues(
                      alpha: active
                          ? (_hasCjk(extra) ? 0.82 : 0.6)
                          : (_hasCjk(extra) ? 0.42 : 0.3),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  static final RegExp _cjk = RegExp(
    r'[\u3400-\u4dbf\u4e00-\u9fff\u3040-\u30ff\uac00-\ud7af]',
  );

  static bool _hasCjk(String text) => _cjk.hasMatch(text);
}

/// 逐字染色：底层是暗色整行，上层是同一位置的高亮整行，按已唱进度裁切。
///
/// 裁切不能用「容器宽度 × 比例」：整行文字在容器里居中，而 [TextPainter] 的
/// 坐标从文字块左上角算起，两者差一个居中偏移，算出来的矩形会落在左侧空白处。
/// 这里改成自绘——整行先排版一次，再把「已唱完的字」和「当前字已唱的部分」
/// 拼成一条路径去裁切高亮层，坐标天然一致，长句折行也不会错。
class _KaraokeText extends StatefulWidget {
  const _KaraokeText({
    required this.text,
    required this.words,
    required this.lineEndMs,
    required this.position,
    required this.style,
    required this.baseColor,
    required this.highlightColor,
  });

  final String text;
  final List<lyrics_api.LyricWord> words;
  final int lineEndMs;
  final ValueListenable<double> position;
  final TextStyle style;
  final Color baseColor;
  final Color highlightColor;

  @override
  State<_KaraokeText> createState() => _KaraokeTextState();
}

class _KaraokeTextState extends State<_KaraokeText> {
  TextPainter? _base;
  TextPainter? _highlight;

  /// 每个逐字片段在排版里的矩形：一个字被折行拆开时会有多段
  List<List<Rect>> _boxes = const <List<Rect>>[];
  List<int> _times = const <int>[];

  double _width = -1;
  String? _text;
  TextStyle? _style;

  @override
  void didUpdateWidget(_KaraokeText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text || oldWidget.style != widget.style) {
      _width = -1;
    }
  }

  @override
  void dispose() {
    _base?.dispose();
    _highlight?.dispose();
    super.dispose();
  }

  /// 排版并量出每个字的矩形；只在文本 / 样式 / 宽度变化时重算
  void _layout(double width) {
    if (_width == width && _text == widget.text && _style == widget.style) {
      return;
    }
    _width = width;
    _text = widget.text;
    _style = widget.style;

    _base?.dispose();
    _highlight?.dispose();
    final TextPainter base = _painter(widget.baseColor, width);
    _base = base;
    _highlight = _painter(widget.highlightColor, width);

    final List<List<Rect>> boxes = <List<Rect>>[];
    int cursor = 0;
    for (final lyrics_api.LyricWord word in widget.words) {
      final int start = widget.text.indexOf(word.text, cursor);
      if (start < 0) {
        boxes.add(const <Rect>[]);
        continue;
      }
      final int end = start + word.text.length;
      boxes.add(
        base
            .getBoxesForSelection(
              TextSelection(baseOffset: start, extentOffset: end),
            )
            .map((TextBox box) => box.toRect())
            .toList(),
      );
      cursor = end;
    }
    _boxes = boxes;
    _times = widget.words
        .map((lyrics_api.LyricWord word) => word.timeMs.toInt())
        .toList();
  }

  TextPainter _painter(Color color, double width) {
    return TextPainter(
      text: TextSpan(
        text: widget.text,
        style: widget.style.copyWith(color: color),
      ),
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.center,
    )..layout(maxWidth: width);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        _layout(constraints.maxWidth);
        final TextPainter base = _base!;
        return Semantics(
          label: widget.text,
          child: ValueListenableBuilder<double>(
            valueListenable: widget.position,
            builder: (BuildContext context, double seconds, Widget? child) {
              return CustomPaint(
                size: base.size,
                painter: KaraokeTextPainter(
                  base: base,
                  highlight: _highlight!,
                  boxes: _boxes,
                  times: _times,
                  lineEndMs: widget.lineEndMs,
                  positionMs: seconds * 1000,
                ),
              );
            },
          ),
        );
      },
    );
  }
}

/// 逐字染色画笔：整行先画暗色，再按已唱进度裁切画一遍高亮。
@visibleForTesting
class KaraokeTextPainter extends CustomPainter {
  KaraokeTextPainter({
    required this.base,
    required this.highlight,
    required this.boxes,
    required this.times,
    required this.lineEndMs,
    required this.positionMs,
  });

  final TextPainter base;
  final TextPainter highlight;
  final List<List<Rect>> boxes;
  final List<int> times;
  final int lineEndMs;
  final double positionMs;

  /// 需要染色的区域（排版坐标）：已唱完的字整块，当前字按进度从左往右
  Path get fillPath {
    final Path path = Path();
    for (int i = 0; i < boxes.length; i += 1) {
      final double start = times[i].toDouble();
      if (positionMs <= start) {
        break;
      }
      final double end = i + 1 < times.length
          ? times[i + 1].toDouble()
          : lineEndMs.toDouble();
      final double progress = end <= start
          ? 1
          : ((positionMs - start) / (end - start)).clamp(0.0, 1.0);
      final List<Rect> rects = boxes[i];
      if (rects.isEmpty) {
        continue;
      }
      if (progress >= 1) {
        for (final Rect rect in rects) {
          path.addRect(rect);
        }
        continue;
      }
      // 一个字被折行拆成多段时，按宽度顺序依次填
      double remain =
          rects.fold<double>(0, (double sum, Rect rect) => sum + rect.width) *
          progress;
      for (final Rect rect in rects) {
        if (remain <= 0) {
          break;
        }
        final double take = math.min(remain, rect.width);
        path.addRect(Rect.fromLTWH(rect.left, rect.top, take, rect.height));
        remain -= take;
      }
    }
    return path;
  }

  @override
  void paint(Canvas canvas, Size size) {
    base.paint(canvas, Offset.zero);
    final Path path = fillPath;
    if (path.getBounds().isEmpty) {
      return;
    }
    canvas.save();
    canvas.clipPath(path);
    highlight.paint(canvas, Offset.zero);
    canvas.restore();
  }

  @override
  bool shouldRepaint(KaraokeTextPainter oldDelegate) =>
      oldDelegate.positionMs != positionMs ||
      oldDelegate.base != base ||
      oldDelegate.highlight != highlight ||
      oldDelegate.boxes != boxes;
}
