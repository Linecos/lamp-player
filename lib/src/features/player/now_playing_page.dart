import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/title_bar.dart';
import '../../common/formatters/duration.dart';
import '../../common/widgets/album_cover.dart';
import '../../rust/api/lyrics.dart' as lyrics_api;
import '../../rust/api/model.dart';
import '../library/library_sort.dart' show trackArtist;
import 'lyrics_view.dart';

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
  });

  final Track? track;
  final bool isPlaying;
  final double position;
  final double duration;
  final bool isAvailable;
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
    this.lyricsLoader,
  });

  final ValueListenable<NowPlayingData> data;
  final Future<void> Function() onTogglePlay;
  final Future<void> Function() onPrevious;
  final Future<void> Function() onNext;
  final Future<void> Function(double seconds) onSeek;
  final LyricsLoader? lyricsLoader;

  @override
  State<NowPlayingPage> createState() => _NowPlayingPageState();
}

class _NowPlayingPageState extends State<NowPlayingPage> {
  lyrics_api.TrackLyrics? _lyrics;
  String? _loadedPath;
  bool _loading = false;

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

  @override
  void initState() {
    super.initState();
    widget.data.addListener(_onData);
    _onData();
  }

  @override
  void dispose() {
    widget.data.removeListener(_onData);
    _position.dispose();
    _track.dispose();
    _playing.dispose();
    _dragPosition.dispose();
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

  /// 切歌时重新读歌词；同一首不重复读
  void _syncTrack() {
    final String? path = widget.data.value.track?.path;
    if (path == null || path == _loadedPath) {
      return;
    }
    _loadedPath = path;
    _lyrics = null;
    unawaited(_loadLyrics(path));
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
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;

    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            Navigator.of(context).maybePop(),
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          backgroundColor: scheme.surfaceContainerLow,
          body: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: <Color>[
                  scheme.surfaceContainerHighest,
                  scheme.surfaceContainerLow,
                ],
              ),
            ),
            child: SafeArea(
              // 标题条浮在页面之上（overlay），顶部 44px 会被它吃掉点击，
              // 不预留这段高度的话收起按钮的上半截永远点不到。
              child: Padding(
                padding: const EdgeInsets.only(top: LampTitleBar.height),
                child: Column(
                  children: <Widget>[
                    _header(context),
                    // 歌词区只监听「曲目」：进度 tick 不该重排整棵歌词列表
                    Expanded(
                      child: ValueListenableBuilder<Track?>(
                        valueListenable: _track,
                        builder: (
                          BuildContext context,
                          Track? track,
                          Widget? child,
                        ) => _body(context, track),
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
      // 与自绘标题栏紧接：按钮/文字中心落在 y≈68（原来 80，明显偏下）
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: SizedBox(
        height: 48,
        child: Row(
          children: <Widget>[
            // 热区只覆盖箭头周围这一圈，标题文字不参与点击。
            IconButton(
              key: const ValueKey<String>('now-playing-collapse'),
              onPressed: () => Navigator.of(context).maybePop(),
              icon: const Icon(Icons.keyboard_arrow_down, size: 22),
              tooltip: '收起',
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints.tightFor(width: 48, height: 48),
            ),
            const SizedBox(width: 4),
            Text('正在播放', style: theme.textTheme.titleMedium),
          ],
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
        final Widget info = _trackInfo(context, track, wide);
        final Widget lyric = _lyricsView(context);
        if (wide) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(32, 8, 32, 0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                SizedBox(width: 300, child: Center(child: info)),
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
              info,
              const SizedBox(height: 12),
              Expanded(child: lyric),
            ],
          ),
        );
      },
    );
  }

  Widget _trackInfo(BuildContext context, Track track, bool wide) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final double coverSize = wide ? 280 : 200;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Center(
          child: ValueListenableBuilder<bool>(
            valueListenable: _playing,
            builder: (BuildContext context, bool playing, Widget? child) {
              return AlbumCover(
                path: track.coverPath,
                size: coverSize,
                radius: 20,
                playing: playing,
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
              ValueListenableBuilder<double?>(
                valueListenable: _dragPosition,
                builder: (BuildContext context, double? drag, Widget? child) {
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
                          overlayShape: const RoundSliderOverlayShape(
                            overlayRadius: 14,
                          ),
                        ),
                        child: Slider(
                          key: const ValueKey<String>('now-playing-progress'),
                          value: total > 0 ? shown : 0,
                          max: total > 0 ? total : 1,
                          onChanged: ready && total > 0
                              ? (double value) => _dragPosition.value = value
                              : null,
                          onChangeEnd: ready && total > 0
                              ? (double value) {
                                  _dragPosition.value = null;
                                  unawaited(widget.onSeek(value));
                                }
                              : null,
                        ),
                      ),
                      Padding(
                        // 12 与上面滑块的 overlay 半径对齐，时间才落在轨道两端内侧
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
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
              const SizedBox(height: 4),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
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
                  IconButton.filled(
                    key: const ValueKey<String>('now-playing-toggle'),
                    iconSize: 34,
                    padding: const EdgeInsets.all(14),
                    onPressed: ready
                        ? () => unawaited(widget.onTogglePlay())
                        : null,
                    icon: Icon(data.isPlaying ? Icons.pause : Icons.play_arrow),
                  ),
                  const SizedBox(width: 12),
                  IconButton(
                    key: const ValueKey<String>('now-playing-next'),
                    iconSize: 30,
                    onPressed: ready ? () => unawaited(widget.onNext()) : null,
                    icon: const Icon(Icons.skip_next),
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
