import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../common/common.dart';
import '../../player/player_bar.dart';
import '../library_sort.dart';
import 'cover_flight.dart';

/// 艺术家网格：圆形首字封面 + 名字 + 专辑/曲目数
class ArtistGridView extends StatelessWidget {
  const ArtistGridView({
    super.key,
    required this.artists,
    required this.onSelect,
    this.storageKey,
    this.flyingTag,
  });

  final List<ArtistGroup> artists;

  /// 第二个参数是卡片封面的屏幕矩形：详情页拿它做「封面飞过去」的起点
  final void Function(ArtistGroup artist, Rect coverRect) onSelect;
  final Key? storageKey;

  /// 正在飞的那张封面（见 [artistCoverTag]）：对应的卡片先把自己藏起来，
  /// 免得飞行层和卡片上的那张同时出现
  final Object? flyingTag;

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      key: storageKey,
      padding: const EdgeInsets.only(
        top: 8,
        // 网格铺到窗口底，卡片可以从播放岛下面穿过；留白保证滚到底时
        // 最后一行停在岛上方
        bottom: PlayerBar.occupiedHeight + 8,
      ),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        // 与专辑网格同宽（220）：两个分区来回切时卡片大小不跳
        maxCrossAxisExtent: 220,
        mainAxisSpacing: 16,
        crossAxisSpacing: 16,
        // 0.86 → 0.76：圆形头像要把「宽度 - 内边距」塞进卡片高度里才够大，
        // 按原来的比例算下来直径只有 127（1080p 窗口），比专辑封面小一圈。
        // 卡片略高一点，头像能到 160 左右，两个分区来回切时观感才对得上
        childAspectRatio: 0.76,
      ),
      itemCount: artists.length,
      itemBuilder: (BuildContext context, int index) {
        final ArtistGroup artist = artists[index];
        final String tag = artistCoverTag(artist.name);
        return _ArtistCard(
          artist: artist,
          onSelect: onSelect,
          hidden: flyingTag == tag,
        );
      },
    );
  }
}

class _ArtistCard extends StatelessWidget {
  _ArtistCard({
    required this.artist,
    required this.onSelect,
    this.hidden = false,
  });

  final ArtistGroup artist;
  final void Function(ArtistGroup artist, Rect coverRect) onSelect;

  /// 这张的封面正在飞行中：先让位给飞行层
  final bool hidden;

  /// 圆形头像：点击时按它量出飞行动画的起点
  final GlobalKey _coverKey = GlobalKey();

  @override
  Widget build(BuildContext context) {
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
        onTap: () => onSelect(artist, rectOfKey(_coverKey) ?? Rect.zero),
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
  });

  final List<AlbumGroup> albums;

  /// 第二个参数是卡片封面的屏幕矩形：详情页拿它做「封面飞过去」的起点
  final void Function(AlbumGroup album, Rect coverRect) onSelect;
  final Key? storageKey;

  /// 见 [ArtistGridView.flyingTag]
  final Object? flyingTag;

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      key: storageKey,
      padding: const EdgeInsets.only(
        top: 8,
        // 网格铺到窗口底，卡片可以从播放岛下面穿过；留白保证滚到底时
        // 最后一行停在岛上方
        bottom: PlayerBar.occupiedHeight + 8,
      ),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 220,
        mainAxisSpacing: 16,
        crossAxisSpacing: 16,
        childAspectRatio: 0.72,
      ),
      itemCount: albums.length,
      itemBuilder: (BuildContext context, int index) {
        final AlbumGroup album = albums[index];
        final String tag = albumCoverTag(album.key);
        return _AlbumCard(
          album: album,
          onSelect: onSelect,
          hidden: flyingTag == tag,
        );
      },
    );
  }
}

class _AlbumCard extends StatelessWidget {
  _AlbumCard({
    required this.album,
    required this.onSelect,
    this.hidden = false,
  });

  final AlbumGroup album;
  final void Function(AlbumGroup album, Rect coverRect) onSelect;

  /// 这张的封面正在飞行中：先让位给飞行层
  final bool hidden;

  /// 封面图：点击时按它量出飞行动画的起点
  final GlobalKey _coverKey = GlobalKey();

  @override
  Widget build(BuildContext context) {
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
        onTap: () => onSelect(album, rectOfKey(_coverKey) ?? Rect.zero),
        hoverColor: scheme.surfaceContainerHigh,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              AspectRatio(
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
