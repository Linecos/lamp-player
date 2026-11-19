part of '../library_page.dart';

/// 音质分档与某一档的曲目子界面。
///
/// 评级是派生量（不落库），分档结果与统计都按 `_tracks` 的对象身份缓存：
/// 切主题、开关侧栏这类重建不该重算一遍全库。
extension _QualitySection on _LibraryPageState {
  Map<AudioQuality, List<Track>> get _tracksByQuality {
    if (identical(_qualityBucketsSource, _tracks) && _qualityBuckets != null) {
      return _qualityBuckets!;
    }
    final Map<AudioQuality, List<Track>> buckets = <AudioQuality, List<Track>>{
      for (final AudioQuality quality in AudioQuality.values)
        quality: <Track>[],
    };
    for (final Track track in _tracks) {
      buckets[audioQualityOf(track)]!.add(track);
    }
    _qualityBuckets = buckets;
    _qualityBucketsSource = _tracks;
    return buckets;
  }

  QualityBreakdown get _qualityBreakdown {
    if (identical(_qualityBreakdownSource, _tracks) &&
        _qualityBreakdownCache != null) {
      return _qualityBreakdownCache!;
    }
    final QualityBreakdown breakdown = QualityBreakdown.of(_tracks);
    _qualityBreakdownCache = breakdown;
    _qualityBreakdownSource = _tracks;
    return breakdown;
  }

  /// 点扇形或图例：打开这一档的曲目子界面。
  ///
  /// 以前是「切到音乐分区 + 挂一枚筛选胶囊」，会把整个音乐页占住、只能点 ×
  /// 恢复，跟「看某一档的东西」这个诉求不匹配。
  void _openQualityDetail(AudioQuality quality) {
    _update(() => _qualityDetail = quality);
  }

  /// 音质子界面：标题行 + 这一档的全部曲目。
  ///
  /// 与听歌统计同一套「分区内切换」：侧栏与播放岛都不动，返回只换内容。
  Widget _buildQualityDetail(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final AudioQuality quality = _qualityDetail!;
    final List<Track> tracks = _tracksByQuality[quality]!;
    final int total = _tracks.length;
    final String percent = total == 0
        ? '0%'
        : '${(tracks.length * 100 / total).toStringAsFixed(1)}%';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            IconButton(
              key: const ValueKey<String>('quality-detail-back'),
              onPressed: () => _update(() => _qualityDetail = null),
              tooltip: '返回音乐库',
              icon: const Icon(Icons.arrow_back),
              visualDensity: VisualDensity.compact,
            ),
            const SizedBox(width: 4),
            Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                color: sliceColor(scheme, quality),
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '${qualityLabel(quality)} · ${qualityCaption(quality)}',
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const Spacer(),
            FilledButton.tonalIcon(
              style: _headerButtonStyle(),
              onPressed: tracks.isEmpty
                  ? null
                  : () => unawaited(_playAll(tracks)),
              icon: const Icon(Icons.play_arrow),
              label: const Text('播放全部'),
            ),
          ],
        ),
        const SizedBox(height: 2),
        Text(
          '${tracks.length} 首 · 占全库 $percent',
          style: theme.textTheme.bodyLarge?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: tracks.isEmpty
              ? EmptyState(
                  icon: Icons.tune,
                  title: '这一档没有歌曲',
                  message:
                      '整个曲库里没有 ${qualityLabel(quality)} '
                      '（${qualityCaption(quality)}）的曲目。',
                )
              : TrackListView(
                  key: ValueKey<String>('quality-detail-${quality.name}'),
                  tracks: tracks,
                  storageKey: PageStorageKey<String>(
                    'tracks:quality-${quality.name}',
                  ),
                  playingPath: _currentTrack?.path,
                  flashPath: _flashTrackPath,
                  onPlay: (Track track) => unawaited(_playFrom(tracks, track)),
                  favoritePaths: _favoritePaths,
                  onToggleFavorite: (Track track) =>
                      unawaited(_toggleFavorite(track)),
                  onContextAction: (Track track, TrackContextAction action) =>
                      _onTrackContext(tracks, track, action),
                ),
        ),
      ],
    );
  }
}
