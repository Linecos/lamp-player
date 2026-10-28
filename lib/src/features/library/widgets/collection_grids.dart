import 'package:flutter/material.dart';

import '../../../common/widgets/album_cover.dart';
import '../../player/player_bar.dart';
import '../library_sort.dart';

/// 取展示用首字：中文取第一个字，英文取首字母。
String initialsOf(String name) {
  final String text = name.trim();
  if (text.isEmpty) {
    return '?';
  }
  return String.fromCharCode(text.runes.first).toUpperCase();
}

/// 艺术家网格：圆形首字封面 + 名字 + 专辑/曲目数
class ArtistGridView extends StatelessWidget {
  const ArtistGridView({
    super.key,
    required this.artists,
    required this.onSelect,
    this.storageKey,
  });

  final List<ArtistGroup> artists;
  final ValueChanged<ArtistGroup> onSelect;
  final Key? storageKey;

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
        maxCrossAxisExtent: 208,
        mainAxisSpacing: 16,
        crossAxisSpacing: 16,
        childAspectRatio: 0.86,
      ),
      itemCount: artists.length,
      itemBuilder: (BuildContext context, int index) {
        final ArtistGroup artist = artists[index];
        return _ArtistCard(artist: artist, onTap: () => onSelect(artist));
      },
    );
  }
}

class _ArtistCard extends StatelessWidget {
  const _ArtistCard({required this.artist, required this.onTap});

  final ArtistGroup artist;
  final VoidCallback onTap;

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
        onTap: onTap,
        hoverColor: scheme.surfaceContainerHigh,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 20, 12, 16),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              Container(
                width: 96,
                height: 96,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: scheme.primaryContainer,
                ),
                alignment: Alignment.center,
                child: Text(
                  initialsOf(artist.name),
                  style: theme.textTheme.headlineSmall?.copyWith(
                    color: scheme.onPrimaryContainer,
                  ),
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
  });

  final List<AlbumGroup> albums;
  final ValueChanged<AlbumGroup> onSelect;
  final Key? storageKey;

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
        return _AlbumCard(album: album, onTap: () => onSelect(album));
      },
    );
  }
}

class _AlbumCard extends StatelessWidget {
  const _AlbumCard({required this.album, required this.onTap});

  final AlbumGroup album;
  final VoidCallback onTap;

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
        onTap: onTap,
        hoverColor: scheme.surfaceContainerHigh,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              AspectRatio(
                aspectRatio: 1,
                child: LayoutBuilder(
                  builder: (BuildContext context, BoxConstraints constraints) {
                    return AlbumCover(
                      path: album.coverPath,
                      size: constraints.maxWidth,
                      // 32 外框 - 12 内边距 = 20，与卡片圆角同心
                      radius: 20,
                    );
                  },
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
