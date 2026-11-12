import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../common/common.dart';
import '../../player/player_bar.dart';
import '../library_sort.dart';
import 'alphabet_grid.dart';
import 'cover_flight.dart';

/// 艺术家网格：圆形首字封面 + 名字 + 专辑/曲目数
class ArtistGridView extends StatelessWidget {
  const ArtistGridView({
    super.key,
    required this.artists,
    required this.onSelect,
    this.storageKey,
    this.flyingTag,
    this.columnWidthHint,
  });

  final List<ArtistGroup> artists;

  /// 第二个参数是卡片封面的屏幕矩形（「封面飞过去」的起点），第三个是它所在
  /// 滚动视口的可见矩形（用来判断卡片有多少被挡住，见 [flyCover] 的 `clip`）
  final void Function(ArtistGroup artist, Rect coverRect, Rect? viewport)
  onSelect;
  final Key? storageKey;

  /// 正在飞的那张封面（见 [artistCoverTag]）：对应的卡片先把自己藏起来，
  /// 免得飞行层和卡片上的那张同时出现
  final Object? flyingTag;

  /// 算列数用的宽度（侧栏展开时的内容区宽度），见 [AlphabetGridView]
  final double? columnWidthHint;

  @override
  Widget build(BuildContext context) {
    // 按艺术家名首字母分段 + 右侧字母导航；卡片与跳转都复用同一套网格
    return AlphabetGridView<ArtistGroup>(
      items: artists,
      labelOf: (ArtistGroup artist) => artist.name,
      storageKey: storageKey,
      maxCrossAxisExtent: 220,
      aspectRatio: 0.76,
      columnWidthHint: columnWidthHint,
      bottomPadding: PlayerBar.occupiedHeight + 8,
      itemBuilder: (BuildContext context, ArtistGroup artist, int index) {
        return _ArtistCard(
          artist: artist,
          onSelect: onSelect,
          hidden: flyingTag == artistCoverTag(artist.name),
        );
      },
    );
  }
}

class _ArtistCard extends StatefulWidget {
  const _ArtistCard({
    required this.artist,
    required this.onSelect,
    this.hidden = false,
  });

  final ArtistGroup artist;
  final void Function(ArtistGroup artist, Rect coverRect, Rect? viewport)
  onSelect;

  /// 这张的封面正在飞行中：先让位给飞行层
  final bool hidden;

  @override
  State<_ArtistCard> createState() => _ArtistCardState();
}

class _ArtistCardState extends State<_ArtistCard> {
  /// 圆形头像：点击时按它量出飞行动画的起点。
  ///
  /// 放 State 里、而不是 widget 的字段：卡片是每次 rebuild 都新建的 widget，
  /// 字段里 new 出来的 `GlobalKey` 每次都不一样，`canUpdate` 判 false 就会把
  /// 整棵子树（含封面图）丢掉重建——图片重新解析、淡入状态全丢。
  final GlobalKey _coverKey = GlobalKey();

  @override
  Widget build(BuildContext context) {
    final ArtistGroup artist = widget.artist;
    final bool hidden = widget.hidden;
    final void Function(ArtistGroup artist, Rect coverRect, Rect? viewport)
    onSelect = widget.onSelect;
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;

    return Material(
      color: scheme.surface,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(32),
        side: BorderSide(color: scheme.outlineVariant),
      ),
      child: InkWell(
        onTap: () => onSelect(
          artist,
          rectOfKey(_coverKey) ?? Rect.zero,
          scrollViewportOf(context),
        ),
        hoverColor: scheme.surfaceContainerHigh,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 20, 12, 16),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              // 头像吃满卡片剩下的高度，再由宽度封顶。写死尺寸两头不对：
              // 卡片宽度随窗口列数在 155–220 之间变，96 在宽窗口显得空，
              // 而按「宽度 - 内边距」算又不一定塞得进 0.86 的卡片高度。
              Expanded(
                child: LayoutBuilder(
                  builder: (BuildContext context, BoxConstraints constraints) {
                    final double size = math.min(
                      constraints.maxWidth,
                      constraints.maxHeight,
                    );
                    return Center(
                      child: SizedBox(
                        key: _coverKey,
                        width: size,
                        height: size,
                        child: CoverFlightTarget(
                          hidden: hidden,
                          child: artistAvatar(
                            context,
                            artist.name,
                            size,
                            coverPath: artist.coverPath,
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 12),
              Text(
                artist.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleMedium,
              ),
              const SizedBox(height: 2),
              Text(
                '${artist.albumCount} 张专辑 · ${artist.trackCount} 首',
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
  }
}

/// 专辑网格：方形占位封面（不伪造封面图）+ 专辑名 + 艺术家
class AlbumGridView extends StatelessWidget {
  const AlbumGridView({
    super.key,
    required this.albums,
    required this.onSelect,
    this.storageKey,
    this.flyingTag,
    this.columnWidthHint,
  });

  final List<AlbumGroup> albums;

  /// 第二个参数是卡片封面的屏幕矩形（「封面飞过去」的起点），第三个是它所在
  /// 滚动视口的可见矩形
  final void Function(AlbumGroup album, Rect coverRect, Rect? viewport)
  onSelect;
  final Key? storageKey;

  /// 见 [ArtistGridView.flyingTag]
  final Object? flyingTag;

  /// 见 [ArtistGridView.columnWidthHint]
  final double? columnWidthHint;

  @override
  Widget build(BuildContext context) {
    // 按专辑名首字母分段 + 右侧字母导航
    return AlphabetGridView<AlbumGroup>(
      items: albums,
      labelOf: (AlbumGroup album) => album.title,
      storageKey: storageKey,
      maxCrossAxisExtent: 220,
      aspectRatio: 0.72,
      columnWidthHint: columnWidthHint,
      bottomPadding: PlayerBar.occupiedHeight + 8,
      itemBuilder: (BuildContext context, AlbumGroup album, int index) {
        return _AlbumCard(
          album: album,
          onSelect: onSelect,
          hidden: flyingTag == albumCoverTag(album.key),
        );
      },
    );
  }
}

class _AlbumCard extends StatefulWidget {
  const _AlbumCard({
    required this.album,
    required this.onSelect,
    this.hidden = false,
  });

  final AlbumGroup album;
  final void Function(AlbumGroup album, Rect coverRect, Rect? viewport)
  onSelect;

  /// 这张的封面正在飞行中：先让位给飞行层
  final bool hidden;

  @override
  State<_AlbumCard> createState() => _AlbumCardState();
}

class _AlbumCardState extends State<_AlbumCard> {
  /// 封面图：点击时按它量出飞行动画的起点。
  ///
  /// 放 State 里（同 [_ArtistCardState._coverKey]）：放在 widget 字段里的话
  /// 每次 rebuild 都换 key，整棵封面子树连同图片订阅一起重建。
  final GlobalKey _coverKey = GlobalKey();

  @override
  Widget build(BuildContext context) {
    final AlbumGroup album = widget.album;
    final bool hidden = widget.hidden;
    final void Function(AlbumGroup album, Rect coverRect, Rect? viewport)
    onSelect = widget.onSelect;
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;

    return Material(
      color: scheme.surface,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(32),
        side: BorderSide(color: scheme.outlineVariant),
      ),
      child: InkWell(
        onTap: () => onSelect(
          album,
          rectOfKey(_coverKey) ?? Rect.zero,
          scrollViewportOf(context),
        ),
        hoverColor: scheme.surfaceContainerHigh,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              // Flexible 是给「侧栏动画开头那几帧」兜底的：那时列数已经按最终
              // 宽度涨上去了，卡片还窄，正方形封面按宽度撑满会顶掉下面两行字
              // （溢出 1~8px）。有它就把封面缩一点，字始终看得见。
              Flexible(
                child: AspectRatio(
                  key: _coverKey,
                  aspectRatio: 1,
                  child: CoverFlightTarget(
                    hidden: hidden,
                    child: LayoutBuilder(
                      builder:
                          (BuildContext context, BoxConstraints constraints) {
                            return AlbumCover(
                              path: album.coverPath,
                              size: constraints.maxWidth,
                              radius: albumCardCoverRadius,
                            );
                          },
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                album.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleMedium,
              ),
              const SizedBox(height: 2),
              Text(
                '${album.artist} · ${album.tracks.length} 首',
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
  }
}
