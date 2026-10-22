import 'package:flutter/material.dart';

import '../../../common/formatters/duration.dart';
import '../../../rust/api/model.dart';
import '../library_sort.dart';

/// 曲库列表：固定表头 + 虚拟滚动（`ListView.builder` + `itemExtent`）。
///
/// 只负责展示与点击回调，数据与播放由页面决定，因此可以在 `test/` 下
/// 用普通 `Track` 列表直接渲染，不依赖 Rust。
class TrackListView extends StatelessWidget {
  const TrackListView({
    super.key,
    required this.tracks,
    required this.onPlay,
    this.playingPath,
  });

  final List<Track> tracks;
  final ValueChanged<Track> onPlay;
  final String? playingPath;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final bool showArtist = constraints.maxWidth >= 720;
        final bool showAlbum = constraints.maxWidth >= 900;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _TrackHeader(showArtist: showArtist, showAlbum: showAlbum),
            Expanded(
              child: ListView.builder(
                itemCount: tracks.length,
                itemExtent: 56,
                padding: EdgeInsets.zero,
                itemBuilder: (BuildContext context, int index) {
                  final Track track = tracks[index];
                  return _TrackRow(
                    track: track,
                    index: index,
                    playing: track.path == playingPath,
                    showArtist: showArtist,
                    showAlbum: showAlbum,
                    onPlay: () => onPlay(track),
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

class _TrackHeader extends StatelessWidget {
  const _TrackHeader({required this.showArtist, required this.showAlbum});

  final bool showArtist;
  final bool showAlbum;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final TextStyle? style = theme.textTheme.labelMedium?.copyWith(
      color: scheme.onSurfaceVariant,
    );

    return Container(
      height: 32,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: scheme.outlineVariant)),
      ),
      child: Row(
        children: <Widget>[
          SizedBox(width: 32, child: Text('#', style: style)),
          const SizedBox(width: 40),
          const SizedBox(width: 12),
          Expanded(flex: 5, child: Text('标题', style: style)),
          if (showArtist) Expanded(flex: 2, child: Text('艺术家', style: style)),
          if (showAlbum) Expanded(flex: 2, child: Text('专辑', style: style)),
          SizedBox(
            width: 64,
            child: Text('时长', textAlign: TextAlign.right, style: style),
          ),
        ],
      ),
    );
  }
}

class _TrackRow extends StatelessWidget {
  const _TrackRow({
    required this.track,
    required this.index,
    required this.playing,
    required this.showArtist,
    required this.showAlbum,
    required this.onPlay,
  });

  final Track track;
  final int index;
  final bool playing;
  final bool showArtist;
  final bool showAlbum;
  final VoidCallback onPlay;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final BorderRadius radius = BorderRadius.circular(16);

    final TextStyle? secondary = theme.textTheme.bodyMedium?.copyWith(
      color: scheme.onSurfaceVariant,
    );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Material(
        color: playing
            ? scheme.primaryContainer.withValues(alpha: 0.35)
            : Colors.transparent,
        borderRadius: radius,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPlay,
          hoverColor: scheme.surfaceContainerHigh,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Row(
              children: <Widget>[
                SizedBox(
                  width: 32,
                  child: Center(
                    child: playing
                        ? Icon(
                            Icons.graphic_eq,
                            size: 18,
                            color: scheme.primary,
                          )
                        : Text(
                            '${index + 1}',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                              fontFeatures: const <FontFeature>[
                                FontFeature.tabularFigures(),
                              ],
                            ),
                          ),
                  ),
                ),
                _TrackCover(playing: playing),
                const SizedBox(width: 12),
                Expanded(
                  flex: 5,
                  child: Text(
                    track.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyLarge?.copyWith(
                      color: playing ? scheme.primary : scheme.onSurface,
                    ),
                  ),
                ),
                if (showArtist)
                  Expanded(
                    flex: 2,
                    child: Text(
                      trackArtist(track),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: secondary,
                    ),
                  ),
                if (showAlbum)
                  Expanded(
                    flex: 2,
                    child: Text(
                      trackAlbum(track),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: secondary,
                    ),
                  ),
                SizedBox(
                  width: 64,
                  child: Text(
                    formatDuration(track.durationSecs),
                    textAlign: TextAlign.right,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                      fontFeatures: const <FontFeature>[
                        FontFeature.tabularFigures(),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _TrackCover extends StatelessWidget {
  const _TrackCover({required this.playing});

  final bool playing;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Icon(
        Icons.music_note,
        size: 20,
        color: playing ? scheme.primary : scheme.onSurfaceVariant,
      ),
    );
  }
}
