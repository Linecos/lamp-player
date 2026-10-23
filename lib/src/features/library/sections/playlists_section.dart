part of '../library_page.dart';

/// 歌单分区
///
/// 从 `_LibraryPageState` 拆出，仍直接读写页面状态：这一轮只做文件切分。
extension _PlaylistsSection on _LibraryPageState {
  /* -------------------------------------------------------------- 歌单 */

  Playlist? get _selectedPlaylist {
    final int? id = _selectedPlaylistId;
    if (id == null) {
      return null;
    }
    for (final Playlist playlist in _playlists) {
      if (playlist.id.toInt() == id) {
        return playlist;
      }
    }
    return null;
  }

  Future<void> _loadPlaylists() async {
    if (_playlistsLoading) {
      return;
    }
    _update(() {
      _playlistsLoading = true;
      _playlistsError = null;
    });
    try {
      final List<Playlist> playlists = await _repository.loadPlaylists();
      if (!mounted) {
        return;
      }
      _update(() {
        _playlists = playlists;
        _playlistsLoading = false;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      _update(() {
        _playlistsError = error;
        _playlistsLoading = false;
      });
    }
  }

  Future<void> _loadPlaylistTracks(int id) async {
    _update(() {
      _playlistTracksLoading = true;
      _playlistTracksError = null;
    });
    try {
      final List<Track> tracks = await _repository.loadPlaylistTracks(id);
      if (!mounted || _selectedPlaylistId != id) {
        return;
      }
      _update(() {
        _playlistTracks = tracks;
        _playlistTracksLoading = false;
      });
    } catch (error) {
      if (!mounted || _selectedPlaylistId != id) {
        return;
      }
      _update(() {
        _playlistTracksError = error;
        _playlistTracksLoading = false;
      });
    }
  }

  Future<void> _openPlaylist(Playlist playlist) async {
    final int id = playlist.id.toInt();
    _update(() {
      _selectedPlaylistId = id;
      _playlistTracks = const <Track>[];
      _playlistTracksLoading = true;
      _playlistTracksError = null;
    });
    await _loadPlaylistTracks(id);
  }

  String? _validatePlaylistName(String name, {int? exceptId}) {
    if (name.isEmpty) {
      return '歌单名不能为空';
    }
    final String lower = name.toLowerCase();
    final bool taken = _playlists.any(
      (Playlist playlist) =>
          playlist.id.toInt() != exceptId &&
          playlist.name.toLowerCase() == lower,
    );
    return taken ? '已有同名歌单' : null;
  }

  Future<void> _createPlaylist({String? addTrackPath}) async {
    final String? name = await showPlaylistNameDialog(
      context,
      title: '新建歌单',
      confirmText: '创建',
      validate: (String value) => _validatePlaylistName(value),
    );
    if (name == null || !mounted) {
      return;
    }
    try {
      final Playlist playlist = await _repository.createPlaylist(name);
      bool added = false;
      String? addError;
      if (addTrackPath != null) {
        try {
          added = await _repository.addTrackToPlaylist(
            playlist.id.toInt(),
            addTrackPath,
          );
        } catch (error) {
          addError = ErrorRetry.describe(error);
        }
      }
      await _loadPlaylists();
      if (!mounted) {
        return;
      }
      if (addError != null) {
        _showMessage('已创建「$name」，但加入曲目失败：$addError');
      } else if (added) {
        _showMessage('已创建「$name」并加入 1 首');
      } else {
        _showMessage('已创建「$name」');
      }
    } catch (error) {
      if (!mounted) {
        return;
      }
      _showMessage('创建失败：${ErrorRetry.describe(error)}');
    }
  }

  /// 把单曲加入歌单：先选已有歌单，也可以现场新建。
  ///
  /// 歌单列表只在进入歌单分区时加载，右键菜单在音乐分区也可能用到，
  /// 所以这里先取一次，避免对话框显示“还没有歌单”而让用户重复新建。
  Future<void> _addToPlaylist(Track track) async {
    await _loadPlaylists();
    if (!mounted) {
      return;
    }
    final PlaylistPick? pick = await showPlaylistPickerDialog(
      context,
      playlists: _playlists,
    );
    if (pick == null || !mounted) {
      return;
    }
    switch (pick) {
      case PickNewPlaylist():
        await _createPlaylist(addTrackPath: track.path);
      case PickExistingPlaylist(:final Playlist playlist):
        final int id = playlist.id.toInt();
        final String name = playlist.name;
        try {
          final bool added = await _repository.addTrackToPlaylist(
            id,
            track.path,
          );
          await _loadPlaylists();
          if (!mounted) {
            return;
          }
          _showMessage(added ? '已加入「$name」' : '「$name」里已经有这首');
        } catch (error) {
          if (!mounted) {
            return;
          }
          _showMessage('加入歌单失败：${ErrorRetry.describe(error)}');
        }
    }
  }

  Future<void> _renamePlaylist(Playlist playlist) async {
    final int id = playlist.id.toInt();
    final String? name = await showPlaylistNameDialog(
      context,
      title: '重命名歌单',
      confirmText: '保存',
      initialName: playlist.name,
      validate: (String value) => _validatePlaylistName(value, exceptId: id),
    );
    if (name == null || !mounted) {
      return;
    }
    try {
      await _repository.renamePlaylist(id, name);
      await _loadPlaylists();
      if (!mounted) {
        return;
      }
      _showMessage('已重命名为「$name」');
    } catch (error) {
      if (!mounted) {
        return;
      }
      _showMessage('重命名失败：${ErrorRetry.describe(error)}');
    }
  }

  Future<void> _deletePlaylist(Playlist playlist) async {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: Text('删除「${playlist.name}」？'),
        content: Text('歌单里的 ${playlist.trackCount} 首不会被删除，只是不再属于这个歌单。'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: scheme.error,
              foregroundColor: scheme.onError,
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('删除歌单'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      return;
    }
    try {
      await _repository.deletePlaylist(playlist.id.toInt());
      if (!mounted) {
        return;
      }
      if (_selectedPlaylistId == playlist.id.toInt()) {
        _update(() => _selectedPlaylistId = null);
      }
      await _loadPlaylists();
      if (!mounted) {
        return;
      }
      _showMessage('已删除「${playlist.name}」');
    } catch (error) {
      if (!mounted) {
        return;
      }
      _showMessage('删除失败：${ErrorRetry.describe(error)}');
    }
  }

  Future<void> _addTracksToPlaylist(Playlist playlist) async {
    final int id = playlist.id.toInt();
    final Set<String> existing = _playlistTracks
        .map((Track track) => track.path)
        .toSet();
    final int? added = await showAddTracksDialog(
      context,
      playlistName: playlist.name,
      tracks: _tracks,
      existingPaths: existing,
      onAdd: (String path) => _repository.addTrackToPlaylist(id, path),
    );
    if (added == null || added == 0 || !mounted) {
      return;
    }
    await _loadPlaylistTracks(id);
    await _loadPlaylists();
    if (!mounted) {
      return;
    }
    _showMessage('已添加 $added 首到「${playlist.name}」');
  }

  Future<void> _removeTrackFromPlaylist(Track track) async {
    final int? id = _selectedPlaylistId;
    if (id == null) {
      return;
    }
    try {
      await _repository.removeTrackFromPlaylist(id, track.path);
      if (!mounted) {
        return;
      }
      _update(() {
        _playlistTracks = _playlistTracks
            .where((Track item) => item.path != track.path)
            .toList();
      });
      await _loadPlaylists();
      if (!mounted) {
        return;
      }
      _showMessage('已从歌单移除「${track.title}」');
    } catch (error) {
      if (!mounted) {
        return;
      }
      _showMessage('移除失败：${ErrorRetry.describe(error)}');
    }
  }

  Widget _buildPlaylistsSection(BuildContext context) {
    final Playlist? selected = _selectedPlaylist;
    if (selected != null) {
      return _buildPlaylistDetail(context, selected);
    }

    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            Text(
              '歌单',
              style: theme.textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const Spacer(),
            FilledButton.icon(
              onPressed: () => unawaited(_createPlaylist()),
              icon: const Icon(Icons.add),
              label: const Text('新建歌单'),
            ),
          ],
        ),
        const SizedBox(height: 2),
        Text(
          '${_playlists.length} 个歌单',
          style: theme.textTheme.bodyLarge?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 8),
        Expanded(child: _buildPlaylistsBody(context)),
      ],
    );
  }

  Widget _buildPlaylistsBody(BuildContext context) {
    if (_playlistsLoading) {
      return const LoadingState(message: '正在读取歌单…');
    }
    if (_playlistsError != null) {
      return ErrorRetry(
        error: _playlistsError!,
        title: '歌单读取失败',
        onRetry: () => unawaited(_loadPlaylists()),
      );
    }
    if (_playlists.isEmpty) {
      return EmptyState(
        icon: Icons.queue_music,
        title: '还没有歌单',
        message: '把常听的曲目收进歌单，之后就不用再翻整个曲库。',
        action: FilledButton.icon(
          onPressed: () => unawaited(_createPlaylist()),
          icon: const Icon(Icons.add),
          label: const Text('新建歌单'),
        ),
      );
    }
    return PlaylistGridView(
      playlists: _playlists,
      storageKey: const PageStorageKey<String>('grid:playlists'),
      onOpen: (Playlist playlist) => unawaited(_openPlaylist(playlist)),
      onAction: (Playlist playlist, PlaylistAction action) {
        switch (action) {
          case PlaylistAction.rename:
            unawaited(_renamePlaylist(playlist));
          case PlaylistAction.delete:
            unawaited(_deletePlaylist(playlist));
        }
      },
    );
  }

  Widget _buildPlaylistDetail(BuildContext context, Playlist playlist) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _DetailBar(
          label: '歌单',
          onBack: () => _update(() => _selectedPlaylistId = null),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Container(
                width: 128,
                height: 128,
                decoration: BoxDecoration(
                  color: scheme.secondaryContainer,
                  borderRadius: BorderRadius.circular(32),
                ),
                child: Icon(
                  Icons.queue_music,
                  size: 48,
                  color: scheme.onSecondaryContainer,
                ),
              ),
              const SizedBox(width: 24),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      playlist.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.headlineSmall,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '${playlist.trackCount} 首 · 更新于 '
                      '${formatPlaylistUpdated(playlist.updatedAt)}',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: <Widget>[
                        FilledButton.icon(
                          onPressed: _playlistTracks.isEmpty
                              ? null
                              : () => unawaited(_playAll(_playlistTracks)),
                          icon: const Icon(Icons.play_arrow),
                          label: const Text('播放全部'),
                        ),
                        FilledButton.tonalIcon(
                          onPressed: () =>
                              unawaited(_addTracksToPlaylist(playlist)),
                          icon: const Icon(Icons.add),
                          label: const Text('添加音乐'),
                        ),
                        OutlinedButton.icon(
                          onPressed: () => unawaited(_renamePlaylist(playlist)),
                          icon: const Icon(Icons.edit_outlined),
                          label: const Text('重命名'),
                        ),
                        OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            foregroundColor: scheme.error,
                          ),
                          onPressed: () => unawaited(_deletePlaylist(playlist)),
                          icon: const Icon(Icons.delete_outline),
                          label: const Text('删除歌单'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Expanded(child: _buildPlaylistTracksBody(context, playlist)),
      ],
    );
  }

  Widget _buildPlaylistTracksBody(BuildContext context, Playlist playlist) {
    if (_playlistTracksLoading && _playlistTracks.isEmpty) {
      return const LoadingState(message: '正在读取歌单…');
    }
    if (_playlistTracksError != null) {
      return ErrorRetry(
        error: _playlistTracksError!,
        title: '歌单读取失败',
        onRetry: () => unawaited(_loadPlaylistTracks(playlist.id.toInt())),
      );
    }
    if (_playlistTracks.isEmpty) {
      return EmptyState(
        icon: Icons.playlist_add,
        title: '歌单还是空的',
        message: '从曲库里挑几首加进来，之后就能在这里直接播放。',
        action: FilledButton.icon(
          onPressed: () => unawaited(_addTracksToPlaylist(playlist)),
          icon: const Icon(Icons.add),
          label: const Text('添加音乐'),
        ),
      );
    }
    return TrackListView(
      tracks: _playlistTracks,
      storageKey: PageStorageKey<String>('tracks:playlist:${playlist.id}'),
      playingPath: _currentTrack?.path,
      onPlay: (Track track) => unawaited(_playFrom(_playlistTracks, track)),
      onRemove: (Track track) => unawaited(_removeTrackFromPlaylist(track)),
      favoritePaths: _favoritePaths,
      onToggleFavorite: (Track track) => unawaited(_toggleFavorite(track)),
      onContextAction: (Track track, TrackContextAction action) =>
          _onTrackContext(_playlistTracks, track, action),
    );
  }
}
