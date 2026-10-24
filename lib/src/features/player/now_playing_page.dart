import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../common/formatters/duration.dart';
import '../../common/widgets/album_cover.dart';
import '../../rust/api/lyrics.dart' as lyrics_api;
import '../../rust/api/model.dart';
import '../library/library_sort.dart' show trackArtist;

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
  final ScrollController _lyricsScroll = ScrollController();

  lyrics_api.TrackLyrics? _lyrics;
  String? _loadedPath;
  bool _loading = false;
  int _activeLine = -1;

  /// 拖动中的预览位置：松手才真正 seek，避免一次拖动发出几十条命令
  double? _dragPosition;

  @override
  void initState() {
    super.initState();
    widget.data.addListener(_onData);
    _syncTrack();
  }

  @override
  void dispose() {
    widget.data.removeListener(_onData);
    _lyricsScroll.dispose();
    super.dispose();
  }

  void _onData() {
    if (!mounted) {
      return;
    }
    _syncTrack();
    final int active = _activeIndex(widget.data.value.position);
    if (active != _activeLine) {
      setState(() => _activeLine = active);
      _scrollToActive(active);
    } else {
      setState(() {});
    }
  }

  /// 切歌时重新读歌词；同一首不重复读
  void _syncTrack() {
    final String? path = widget.data.value.track?.path;
    if (path == null || path == _loadedPath) {
      return;
    }
    _loadedPath = path;
    _lyrics = null;
    _activeLine = -1;
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
      // 打开页面时可能已经播到一半：立即定位当前行，而不是等下一次进度刷新
      _activeLine = _activeIndex(widget.data.value.position);
    });
    _scrollToActive(_activeLine);
  }

  int _activeIndex(double position) {
    final List<lyrics_api.LyricLine> lines = _lyrics?.lines ?? const [];
    if (lines.isEmpty) {
      return -1;
    }
    final int ms = (position * 1000).round();
    int index = -1;
    for (int i = 0; i < lines.length; i += 1) {
      if (lines[i].timeMs.toInt() <= ms) {
        index = i;
      } else {
        break;
      }
    }
    return index;
  }

  void _scrollToActive(int index) {
    if (index < 0 || !_lyricsScroll.hasClients) {
      return;
    }
    // 让当前行停在视口中部：固定行高便于计算，不做测量
    const double lineExtent = 44;
    final double target =
        (index * lineExtent - _lyricsScroll.position.viewportDimension / 2 + 22)
            .clamp(0.0, _lyricsScroll.position.maxScrollExtent);
    unawaited(
      _lyricsScroll.animateTo(
        target,
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOut,
      ),
    );
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
              child: ValueListenableBuilder<NowPlayingData>(
                valueListenable: widget.data,
                builder: (BuildContext context, NowPlayingData data, _) {
                  return Column(
                    children: <Widget>[
                      _header(context),
                      Expanded(child: _body(context, data)),
                      _controls(context, data),
                      const SizedBox(height: 12),
                    ],
                  );
                },
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
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
      child: Row(
        children: <Widget>[
          IconButton(
            onPressed: () => Navigator.of(context).maybePop(),
            icon: const Icon(Icons.keyboard_arrow_down),
            tooltip: '收起',
          ),
          Text('正在播放', style: theme.textTheme.titleMedium),
        ],
      ),
    );
  }

  Widget _body(BuildContext context, NowPlayingData data) {
    final Track? track = data.track;
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
          child: AlbumCover(
            path: track.coverPath,
            size: coverSize,
            radius: 20,
            playing: widget.data.value.isPlaying,
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
        controller: _lyricsScroll,
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Text(
          lyrics.plain,
          style: theme.textTheme.bodyLarge?.copyWith(height: 1.7),
        ),
      );
    }

    return ListView.builder(
      controller: _lyricsScroll,
      padding: const EdgeInsets.symmetric(vertical: 80),
      itemCount: lyrics.lines.length,
      itemExtent: 44,
      itemBuilder: (BuildContext context, int index) {
        final lyrics_api.LyricLine line = lyrics.lines[index];
        final bool active = index == _activeLine;
        return InkWell(
          key: ValueKey<String>('lyric-$index'),
          onTap: () => unawaited(widget.onSeek(line.timeMs.toInt() / 1000)),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              line.text.isEmpty ? '♪' : line.text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyLarge?.copyWith(
                height: 2.2,
                fontSize: active ? 19 : 16,
                fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                color: active ? scheme.primary : scheme.onSurfaceVariant,
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _controls(BuildContext context, NowPlayingData data) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final bool ready = data.isAvailable && data.track != null;
    final double total = data.duration > 0 ? data.duration : 0;
    final double shown = data.position.clamp(0.0, total).toDouble();

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        children: <Widget>[
          Slider(
            key: const ValueKey<String>('now-playing-progress'),
            value: total > 0 ? (_dragPosition ?? shown) : 0,
            max: total > 0 ? total : 1,
            onChanged: ready && total > 0
                ? (double value) => setState(() => _dragPosition = value)
                : null,
            onChangeEnd: ready && total > 0
                ? (double value) {
                    setState(() => _dragPosition = null);
                    unawaited(widget.onSeek(value));
                  }
                : null,
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: <Widget>[
                Text(
                  formatDuration(_dragPosition ?? shown),
                  style: theme.textTheme.bodySmall,
                ),
                Text(formatDuration(total), style: theme.textTheme.bodySmall),
              ],
            ),
          ),
          const SizedBox(height: 4),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              IconButton(
                key: const ValueKey<String>('now-playing-previous'),
                iconSize: 30,
                onPressed: ready ? () => unawaited(widget.onPrevious()) : null,
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
  }
}
