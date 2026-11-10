import 'package:flutter/material.dart';

import '../../common/widgets/artist_avatar.dart';

/// 多艺术家选择弹窗。
///
/// 一首歌的艺术家标签里可能用 `/` 隔开好几位
/// 点「查看艺术家」时没法直接决定去哪一位——列出来让用户自己选。
///
/// 返回值：选中的艺术家名；用户直接关掉时返回 `null`。
/// 视觉与输出设备 / 播放队列那几个弹窗同一套：图标 + 标题 + 列表。
Future<String?> showArtistPickerDialog(
  BuildContext context, {
  required List<String> artists,
}) {
  return showDialog<String>(
    context: context,
    builder: (BuildContext context) => _ArtistPickerDialog(artists: artists),
  );
}

class _ArtistPickerDialog extends StatelessWidget {
  const _ArtistPickerDialog({required this.artists});

  final List<String> artists;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      key: const ValueKey<String>('artist-picker-dialog'),
      // 子节点不允许画到 28px 圆角外面（与其它弹窗一致）
      clipBehavior: Clip.antiAlias,
      titlePadding: const EdgeInsets.fromLTRB(24, 16, 12, 8),
      contentPadding: const EdgeInsets.only(bottom: 8),
      title: Row(
        children: <Widget>[
          const Icon(Icons.person_outline, size: 22),
          const SizedBox(width: 10),
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
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
              children: <Widget>[
                for (final String artist in artists) _ArtistRow(name: artist),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ArtistRow extends StatelessWidget {
  const _ArtistRow({required this.name});

  final String name;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Material(
        type: MaterialType.transparency,
        borderRadius: BorderRadius.circular(16),
        child: ListTile(
          key: ValueKey<String>('artist-picker-$name'),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          // 这里仍用首字母：弹窗只知道名字（没有曲库），而列表里几位候选
          // 如果都塞同一张「正在播的这首」的封面，反而分不出谁是谁
          leading: artistInitialsAvatar(context, name, 36),
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
