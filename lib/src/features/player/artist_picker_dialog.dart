import 'package:flutter/material.dart';

import '../../common/scroll/smooth_scroll.dart';
import '../../common/widgets/artist_avatar.dart';
import '../../theme/tokens.dart';

/// 多艺术家选择弹窗。
///
/// 一首歌的艺术家标签里可能用 `/` 隔开好几位
/// 点「查看艺术家」时没法直接决定去哪一位——列出来让用户自己选。
///
/// 返回值：选中的艺术家名；用户直接关掉时返回 `null`。
/// 视觉与输出设备 / 播放队列那几个弹窗同一套：图标 + 标题 + 列表。
///
/// [coverPathOf] 由调用方注入：弹窗自己没有曲库，只知道名字。给了就按名字取
/// 这位艺术家的头像（曲库里第一首带封面的曲目 / 自定义封面），取不到才回退
/// 首字母——两位候选各自有封面，才认得出谁是谁。
///
/// `theme` 用于「正在播放页」：那一页在浅色模式下给自己套了深色前景，
/// 弹窗会跟着捕获过去；这里覆回应用级主题，弹窗与全站其余弹窗同色。
Future<String?> showArtistPickerDialog(
  BuildContext context, {
  required List<String> artists,
  String? Function(String artist)? coverPathOf,
  ThemeData? theme,
}) {
  return showDialog<String>(
    context: context,
    builder: (BuildContext dialogContext) {
      final Widget dialog = _ArtistPickerDialog(
        artists: artists,
        coverPathOf: coverPathOf,
      );
      return theme == null ? dialog : Theme(data: theme, child: dialog);
    },
  );
}

class _ArtistPickerDialog extends StatelessWidget {
  const _ArtistPickerDialog({required this.artists, this.coverPathOf});

  final List<String> artists;
  final String? Function(String artist)? coverPathOf;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      key: const ValueKey<String>('artist-picker-dialog'),
      // 子节点不允许画到 28px 圆角外面（与其它弹窗一致）
      clipBehavior: Clip.antiAlias,
      titlePadding: const EdgeInsets.fromLTRB(
        Spacing.lg,
        Spacing.md,
        Spacing.sm,
        Spacing.xs,
      ),
      contentPadding: const EdgeInsets.only(bottom: Spacing.xs),
      title: Row(
        children: <Widget>[
          const Icon(Icons.person_outline, size: 22),
          const SizedBox(width: Spacing.sm),
          const Expanded(child: Text('选择艺术家')),
          IconButton(
            tooltip: '关闭',
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.close, size: 20),
          ),
        ],
      ),
      content: SizedBox(
        width: 400,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 360),
          // 列表自己的透明 Material：悬停与点击的水波纹只落在列表里
          child: Material(
            type: MaterialType.transparency,
            child: SmoothListView(
              shrinkWrap: true,
              padding: const EdgeInsets.fromLTRB(
                Spacing.xs,
                Spacing.xxs,
                Spacing.xs,
                Spacing.xxs,
              ),
              children: <Widget>[
                for (final String artist in artists)
                  _ArtistRow(
                    name: artist,
                    coverPath: coverPathOf?.call(artist),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ArtistRow extends StatelessWidget {
  const _ArtistRow({required this.name, this.coverPath});

  final String name;

  /// 这位艺术家的封面；没有时才回退首字母
  final String? coverPath;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Material(
        type: MaterialType.transparency,
        borderRadius: BorderRadius.circular(Radii.md),
        child: ListTile(
          key: ValueKey<String>('artist-picker-$name'),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(Radii.md),
          ),
          // 与艺术家卡片 / 详情头部同一个组件：圆形裁切、有封面用封面
          leading: artistAvatar(context, name, 36, coverPath: coverPath),
          title: Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyLarge,
          ),
          onTap: () => Navigator.of(context).pop(name),
        ),
      ),
    );
  }
}
