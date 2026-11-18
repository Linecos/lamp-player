part of '../library_page.dart';

/// 音质筛选：音乐库页的环形图点扇区 → 音乐分区只看这一档。
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

  /// 把音质筛选叠在（搜索或全量）列表上
  List<Track> _applyQualityFilter(List<Track> tracks) {
    final AudioQuality? quality = _qualityFilter;
    if (quality == null) {
      return tracks;
    }
    // 全库列表直接取缓存好的那一档，别又一次遍历全库
    if (identical(tracks, _tracks)) {
      return _tracksByQuality[quality]!;
    }
    return tracks
        .where((Track track) => audioQualityOf(track) == quality)
        .toList(growable: false);
  }

  /// 点扇形 / 点图例：同一档再点一次等于取消
  void _toggleQualityFilter(AudioQuality quality) {
    final bool same = _qualityFilter == quality;
    if (same) {
      _update(() => _qualityFilter = null);
      return;
    }
    // 搜索词还在的话，点扇区看到的是「关键词 ∩ 这一档」，会被误认为扇区没生效
    if (_query.isNotEmpty) {
      _clearSearch();
    }
    _update(() => _qualityFilter = quality);
    if (_section != LibrarySection.music) {
      _selectSection(LibrarySection.music);
    }
  }

  /// 筛出来的这一档是空的（全库都没有，或搜索 + 筛选的交集为空）
  Widget _qualityEmptyState() {
    final AudioQuality? quality = _qualityFilter;
    final String message = quality == null
        ? '没有符合条件的曲目。'
        : _query.isEmpty
        ? '整个曲库里没有 ${qualityLabel(quality)} 的曲目。'
        : '「$_query」里没有 ${qualityLabel(quality)} 的曲目。';
    return EmptyState(
      icon: Icons.tune,
      title: '这一档没有歌曲',
      message: message,
      action: TextButton(
        onPressed: () => _update(() => _qualityFilter = null),
        child: const Text('查看全部'),
      ),
    );
  }

  /// 音乐分区标题行上的「只看 HR · 48 首 ×」
  Widget _buildQualityFilterChip(BuildContext context) {
    final AudioQuality? quality = _qualityFilter;
    if (quality == null) {
      return const SizedBox.shrink();
    }
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(left: 8),
      child: InputChip(
        key: const ValueKey<String>('quality-filter-chip'),
        avatar: Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: sliceColor(scheme, quality),
            shape: BoxShape.circle,
          ),
        ),
        label: Text(
          '只看 ${qualityLabel(quality)} · ${_qualityBreakdown.countOf(quality)} 首',
          style: theme.textTheme.labelMedium,
        ),
        onDeleted: () => _update(() => _qualityFilter = null),
        deleteButtonTooltipMessage: '清除音质筛选',
        visualDensity: VisualDensity.compact,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    );
  }
}
