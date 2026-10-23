import 'package:flutter/material.dart';

import '../../../common/common.dart';
import '../../../rust/api/model.dart';
import '../library_sort.dart';

/// 歌单命名对话框（新建 / 重命名共用）。
///
/// [validate] 返回错误文案时留在对话框里提示；返回 null 才关闭。
Future<String?> showPlaylistNameDialog(
  BuildContext context, {
  required String title,
  required String confirmText,
  required String? Function(String name) validate,
  String initialName = '',
}) {
  return showDialog<String>(
    context: context,
    builder: (BuildContext context) => _PlaylistNameDialog(
      title: title,
      confirmText: confirmText,
      validate: validate,
      initialName: initialName,
    ),
  );
}

class _PlaylistNameDialog extends StatefulWidget {
  const _PlaylistNameDialog({
    required this.title,
    required this.confirmText,
    required this.validate,
    required this.initialName,
  });

  final String title;
  final String confirmText;
  final String? Function(String name) validate;
  final String initialName;

  @override
  State<_PlaylistNameDialog> createState() => _PlaylistNameDialogState();
}

class _PlaylistNameDialogState extends State<_PlaylistNameDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialName,
  );
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final String name = _controller.text.trim();
    final String? error = widget.validate(name);
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    Navigator.of(context).pop(name);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 420,
        child: TextField(
          controller: _controller,
          autofocus: true,
          maxLength: 40,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _submit(),
          onChanged: (_) {
            if (_error != null) {
              setState(() => _error = null);
            }
          },
          decoration: InputDecoration(
            labelText: '歌单名',
            hintText: '例如：深夜通勤',
            errorText: _error,
            counterText: '',
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _submit, child: Text(widget.confirmText)),
      ],
    );
  }
}

/// 右键「添加到歌单」的选择结果。
sealed class PlaylistPick {
  const PlaylistPick();
}

/// 选中已有歌单。
final class PickExistingPlaylist extends PlaylistPick {
  const PickExistingPlaylist(this.playlist);

  final Playlist playlist;
}

/// 要求新建歌单（创建后把曲目加进去）。
final class PickNewPlaylist extends PlaylistPick {
  const PickNewPlaylist();
}

/// 选择目标歌单：列出已有歌单，也可以直接新建。
Future<PlaylistPick?> showPlaylistPickerDialog(
  BuildContext context, {
  required List<Playlist> playlists,
}) {
  return showDialog<PlaylistPick>(
    context: context,
    builder: (BuildContext context) {
      final ThemeData theme = Theme.of(context);
      return AlertDialog(
        title: const Text('添加到歌单'),
        content: SizedBox(
          width: 420,
          height: 340,
          child: playlists.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      '还没有歌单，点右下角新建一个。',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                )
              : ListView.builder(
                  itemCount: playlists.length,
                  itemBuilder: (BuildContext context, int index) {
                    final Playlist playlist = playlists[index];
                    return ListTile(
                      leading: const Icon(Icons.queue_music),
                      title: Text(
                        playlist.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text('${playlist.trackCount} 首'),
                      onTap: () =>
                          Navigator.of(context)
                              .pop(PickExistingPlaylist(playlist)),
                    );
                  },
                ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          FilledButton.tonalIcon(
            onPressed: () => Navigator.of(context).pop(const PickNewPlaylist()),
            icon: const Icon(Icons.add),
            label: const Text('新建歌单'),
          ),
        ],
      );
    },
  );
}

/// 往歌单里加曲目：搜索 + 逐首添加，返回实际新增数量。
Future<int?> showAddTracksDialog(
  BuildContext context, {
  required String playlistName,
  required List<Track> tracks,
  required Set<String> existingPaths,
  required Future<bool> Function(String path) onAdd,
}) {
  return showDialog<int>(
    context: context,
    builder: (BuildContext context) => _AddTracksDialog(
      playlistName: playlistName,
      tracks: tracks,
      existingPaths: existingPaths,
      onAdd: onAdd,
    ),
  );
}

class _AddTracksDialog extends StatefulWidget {
  const _AddTracksDialog({
    required this.playlistName,
    required this.tracks,
    required this.existingPaths,
    required this.onAdd,
  });

  final String playlistName;
  final List<Track> tracks;
  final Set<String> existingPaths;
  final Future<bool> Function(String path) onAdd;

  @override
  State<_AddTracksDialog> createState() => _AddTracksDialogState();
}

class _AddTracksDialogState extends State<_AddTracksDialog> {
  final TextEditingController _queryController = TextEditingController();
  final Set<String> _added = <String>{};
  final Set<String> _busy = <String>{};
  int _count = 0;

  @override
  void dispose() {
    _queryController.dispose();
    super.dispose();
  }

  List<Track> get _candidates {
    final String query = _queryController.text.trim().toLowerCase();
    return widget.tracks
        .where((Track track) {
          if (widget.existingPaths.contains(track.path)) {
            return false;
          }
          if (query.isEmpty) {
            return true;
          }
          final String haystack =
              '${track.title} ${trackArtist(track)} ${trackAlbum(track)}'
                  .toLowerCase();
          return haystack.contains(query);
        })
        .take(300)
        .toList();
  }

  Future<void> _add(Track track) async {
    if (_busy.contains(track.path) || _added.contains(track.path)) {
      return;
    }
    setState(() => _busy.add(track.path));
    try {
      final bool added = await widget.onAdd(track.path);
      if (!mounted) {
        return;
      }
      setState(() {
        _busy.remove(track.path);
        _added.add(track.path);
        if (added) {
          _count += 1;
        }
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _busy.remove(track.path));
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('添加失败：${ErrorRetry.describe(error)}')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final List<Track> candidates = _candidates;
    final bool hasAnyCandidate = widget.tracks.any(
      (Track track) => !widget.existingPaths.contains(track.path),
    );

    return AlertDialog(
      title: Text('添加到「${widget.playlistName}」'),
      content: SizedBox(
        width: 520,
        height: 420,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            TextField(
              controller: _queryController,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                hintText: '搜索标题、艺术家或专辑',
                prefixIcon: Icon(Icons.search),
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: candidates.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          !hasAnyCandidate ? '曲库里的曲目都已经在这个歌单里了' : '没有匹配的曲目',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    )
                  : ListView.separated(
                      itemCount: candidates.length,
                      separatorBuilder: (_, _) => Divider(
                        height: 1,
                        color: scheme.outlineVariant.withValues(alpha: 0.5),
                      ),
                      itemBuilder: (BuildContext context, int index) {
                        final Track track = candidates[index];
                        final bool added = _added.contains(track.path);
                        final bool busy = _busy.contains(track.path);
                        return ListTile(
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 4,
                          ),
                          leading: Container(
                            width: 40,
                            height: 40,
                            decoration: BoxDecoration(
                              color: scheme.surfaceContainerHighest,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Icon(
                              Icons.music_note,
                              size: 20,
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                          title: Text(
                            track.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            '${trackArtist(track)} · ${trackAlbum(track)}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: added
                              ? Icon(Icons.check, color: scheme.primary)
                              : IconButton(
                                  tooltip: '添加到歌单',
                                  onPressed: busy ? null : () => _add(track),
                                  icon: busy
                                      ? const SizedBox(
                                          width: 18,
                                          height: 18,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                          ),
                                        )
                                      : const Icon(Icons.add),
                                ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(_count),
          child: const Text('完成'),
        ),
      ],
    );
  }
}
