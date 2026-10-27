part of '../library_page.dart';

/// 多选与批量操作
///
/// 选择状态收敛在页面，列表只负责画复选框并转发点击；批量操作复用仓库的
/// 批量接口，避免出现「单曲能写、批量绕过校验」两套语义。
extension _SelectionSection on _LibraryPageState {
  /// 当前分区里正在展示的曲目；批量操作只作用于这份列表。
  List<Track> get _selectionVisibleTracks {
    switch (_section) {
      case LibrarySection.music:
        return _query.isEmpty ? _tracks : (_results ?? const <Track>[]);
      case LibrarySection.favorites:
        return _filterTracks(_favoriteTracks);
      case LibrarySection.history:
        return _filterTracks(_historyTracks);
      case LibrarySection.playlists:
        return _selectedPlaylistId == null
            ? const <Track>[]
            : _filterTracks(_playlistTracks);
      case LibrarySection.artists:
        final String? name = _selectedArtist;
        if (name == null) {
          return const <Track>[];
        }
        for (final ArtistGroup group in _artistGroupsCache) {
          if (group.name == name) {
            return _filterTracks(group.tracks);
          }
        }
        return const <Track>[];
      case LibrarySection.albums:
        final String? key = _selectedAlbumKey;
        if (key == null) {
          return const <Track>[];
        }
        for (final AlbumGroup group in _albumGroupsCache) {
          if (group.key == key) {
            return _filterTracks(group.tracks);
          }
        }
        return const <Track>[];
      case LibrarySection.settings:
        return const <Track>[];
    }
  }

  /// 歌单详情里的「移除」只移出歌单；其余分区才是从曲库删记录。
  bool get _selectionInPlaylist =>
      _section == LibrarySection.playlists && _selectedPlaylistId != null;

  /// 已选曲目，按当前列表顺序返回（播放 / 入队顺序与界面一致）。
  List<Track> get _selectedTracks {
    final Set<String> selected = _selectedPaths;
    return _selectionVisibleTracks
        .where((Track track) => selected.contains(track.path))
        .toList();
  }

  bool get _selectionAllFavored {
    final List<Track> tracks = _selectedTracks;
    return tracks.isNotEmpty &&
        tracks.every((Track track) => _favoritePaths.contains(track.path));
  }

  void _toggleSelectionMode() {
    if (_selectionMode) {
      _exitSelection();
      return;
    }
    _update(() => _selectionMode = true);
  }

  void _exitSelection() {
    if (!_selectionMode && _selectedPaths.isEmpty) {
      return;
    }
    _update(() {
      _selectionMode = false;
      _selectedPaths = <String>{};
      _selectionAnchorPath = null;
    });
  }

  /// 切分区 / 搜索 / 进详情时清空选择，避免批量操作作用到看不见的曲目。
  void _clearSelection() {
    if (!_selectionMode && _selectedPaths.isEmpty) {
      return;
    }
    _update(() {
      _selectionMode = false;
      _selectedPaths = <String>{};
      _selectionAnchorPath = null;
    });
  }

  /// 列表行被点击（多选模式或按住 Ctrl / Shift 时）。
  ///
  /// - 普通点击：切换该行（多选模式下不需要按 Ctrl）；
  /// - Ctrl：同样切换，兼容桌面习惯；
  /// - Shift：从锚点到最后点击行的范围加入选择。
  void _onTrackSelect(
    List<Track> visible,
    Track track, {
    required bool toggle,
    required bool range,
  }) {
    final Set<String> available = visible
        .map((Track item) => item.path)
        .toSet();
    _update(() {
      if (!_selectionMode) {
        _selectionMode = true;
        _selectedPaths = <String>{};
        _selectionAnchorPath = null;
      }
      // 列表刷新后可能已经删掉某些曲目，先把失效选择清掉
      _selectedPaths.removeWhere((String path) => !available.contains(path));

      final String? anchor = _selectionAnchorPath;
      if (range && anchor != null && anchor != track.path) {
        final int from = visible.indexWhere(
          (Track item) => item.path == anchor,
        );
        final int to = visible.indexWhere(
          (Track item) => item.path == track.path,
        );
        if (from >= 0 && to >= 0) {
          final int start = from < to ? from : to;
          final int end = from < to ? to : from;
          for (int index = start; index <= end; index += 1) {
            _selectedPaths.add(visible[index].path);
          }
          return;
        }
      }

      if (toggle && _selectedPaths.contains(track.path)) {
        _selectedPaths.remove(track.path);
      } else {
        _selectedPaths.add(track.path);
      }
      _selectionAnchorPath = track.path;
    });
  }

  void _toggleSelectAll() {
    final List<Track> visible = _selectionVisibleTracks;
    final bool allSelected =
        visible.isNotEmpty &&
        visible.every((Track track) => _selectedPaths.contains(track.path));
    _update(() {
      _selectedPaths = allSelected
          ? <String>{}
          : visible.map((Track track) => track.path).toSet();
    });
  }

  Widget _buildSelectionToggle(BuildContext context) {
    return OutlinedButton.icon(
      key: const ValueKey<String>('library-selection-toggle'),
      onPressed: _toggleSelectionMode,
      icon: Icon(_selectionMode ? Icons.close : Icons.checklist),
      label: Text(_selectionMode ? '退出多选' : '多选'),
    );
  }

  Widget _buildSelectionBar(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final int count = _selectedPaths.length;
    final List<Track> visible = _selectionVisibleTracks;
    final bool allSelected =
        visible.isNotEmpty &&
        visible.every((Track track) => _selectedPaths.contains(track.path));
    final bool enabled = count > 0;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
      child: Material(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(20),
        clipBehavior: Clip.antiAlias,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
          child: Row(
            children: <Widget>[
              Text(
                '已选 $count 首',
                key: const ValueKey<String>('library-selection-count'),
                style: theme.textTheme.labelLarge?.copyWith(
                  color: scheme.onSecondaryContainer,
                ),
              ),
              const SizedBox(width: 8),
              TextButton(
                onPressed: visible.isEmpty ? null : _toggleSelectAll,
                child: Text(allSelected ? '取消全选' : '全选'),
              ),
              IconButton(
                tooltip: '播放所选',
                onPressed: enabled ? () => unawaited(_playSelected()) : null,
                icon: const Icon(Icons.play_arrow),
              ),
              IconButton(
                tooltip: '加入队列',
                onPressed: enabled ? _enqueueSelected : null,
                icon: const Icon(Icons.queue_music),
              ),
              IconButton(
                tooltip: _selectionAllFavored ? '取消收藏所选' : '收藏所选',
                onPressed: enabled
                    ? () => unawaited(_favoriteSelected())
                    : null,
                icon: Icon(
                  _selectionAllFavored ? Icons.favorite : Icons.favorite_border,
                ),
              ),
              IconButton(
                tooltip: '加入歌单',
                onPressed: enabled
                    ? () => unawaited(_addSelectedToPlaylist())
                    : null,
                icon: const Icon(Icons.playlist_add),
              ),
              IconButton(
                tooltip: '计算 ReplayGain',
                onPressed: enabled
                    ? () => unawaited(_computeReplayGainForSelected())
                    : null,
                icon: const Icon(Icons.graphic_eq),
              ),
              IconButton(
                tooltip: _selectionInPlaylist ? '从歌单移除' : '从曲库移除',
                onPressed: enabled ? () => unawaited(_removeSelected()) : null,
                icon: Icon(
                  _selectionInPlaylist
                      ? Icons.playlist_remove
                      : Icons.delete_outline,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /* ---------------------------------------------------------- 批量操作 */

  Future<void> _playSelected() async {
    final List<Track> tracks = _selectedTracks;
    if (tracks.isEmpty) {
      return;
    }
    await _playFrom(tracks, tracks.first);
  }

  void _enqueueSelected() {
    final List<Track> tracks = _selectedTracks;
    if (tracks.isEmpty) {
      return;
    }
    if (_queue.isEmpty) {
      // 队列为空时「加入队列」没有落点，直接按「播放所选」处理
      unawaited(_playFrom(tracks, tracks.first));
      _showMessage('已开始播放 ${tracks.length} 首');
      return;
    }
    int added = 0;
    for (final Track track in tracks) {
      if (_queue.append(track)) {
        added += 1;
      }
    }
    _update(() {});
    if (added > 0) {
      _saveSessionNow();
    }
    _showMessage(added > 0 ? '已加入 $added 首到队列' : '所选曲目都已在队列里');
  }

  /// 多选批量计算 ReplayGain：逐首分析整曲响度，写进文件标签，再重扫让曲库跟上。
  ///
  /// 写标签是**改用户文件**，所以先弹确认；取消只在两首之间生效（单首解码中
  /// 断没有意义，中断反而会留下只算一半的结果）。
  Future<void> _computeReplayGainForSelected() async {
    final List<Track> tracks = _selectedTracks;
    if (tracks.isEmpty) {
      return;
    }
    if (_scanning) {
      _showMessage('正在扫描曲库，请稍后再计算');
      return;
    }
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: Text('计算 ${tracks.length} 首曲目的 ReplayGain？'),
        content: const Text(
          '会逐首分析整曲响度（EBU R128），并把结果写进音频文件的 '
          'REPLAYGAIN_TRACK_GAIN 标签：文件会被修改（只加这一个标签，'
          '已有的同名标签会被覆盖），每首约需 1 秒。',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('开始计算'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      return;
    }
    await _runReplayGain(tracks);
  }

  Future<void> _runReplayGain(List<Track> tracks) async {
    final ValueNotifier<_ReplayGainProgress> progress =
        ValueNotifier<_ReplayGainProgress>(
          _ReplayGainProgress(0, tracks.length, ''),
        );
    bool cancelled = false;
    bool dialogOpen = true;

    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (BuildContext dialogContext) => AlertDialog(
          title: const Text('正在计算 ReplayGain'),
          content: ValueListenableBuilder<_ReplayGainProgress>(
            valueListenable: progress,
            builder: (BuildContext context, _ReplayGainProgress value, _) {
              final double ratio = value.total == 0
                  ? 0
                  : value.done / value.total;
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  LinearProgressIndicator(value: ratio),
                  const SizedBox(height: 12),
                  Text(
                    '${value.done}/${value.total}：${value.title}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              );
            },
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () {
                cancelled = true;
                if (dialogOpen) {
                  dialogOpen = false;
                  Navigator.of(dialogContext).pop();
                }
              },
              child: const Text('取消'),
            ),
          ],
        ),
      ),
    );

    int written = 0;
    int failed = 0;
    double sum = 0;
    final Set<String> folders = <String>{};
    for (final Track track in tracks) {
      if (cancelled) {
        break;
      }
      progress.value = _ReplayGainProgress(
        written + failed,
        tracks.length,
        track.title,
      );
      try {
        final double gain = await _playback.analyzeReplayGain(track.path);
        await _repository.writeReplayGain(track.path, gain);
        _autoGains[track.path] = gain;
        written += 1;
        sum += gain;
        folders.add(p.dirname(track.path));
      } catch (_) {
        failed += 1;
      }
    }
    if (dialogOpen && mounted) {
      dialogOpen = false;
      Navigator.of(context, rootNavigator: true).pop();
    }
    progress.dispose();
    if (!mounted) {
      return;
    }

    // 标签改过之后曲库里的增益还是旧的：重扫受影响目录，增量只重解析改过的文件
    for (final String folder in folders) {
      try {
        await _repository.scanFolder(folder);
      } catch (_) {
        // 重扫失败不影响标签已经写进文件，下次扫描会补上
      }
    }
    if (folders.isNotEmpty) {
      await _loadTracks(silent: true);
    }
    if (!mounted) {
      return;
    }

    final String average = written == 0
        ? ''
        : '，平均 ${(sum / written).toStringAsFixed(1)} dB';
    _showMessage(
      cancelled
          ? '已取消：完成 $written 首$average，其余未处理'
          : failed == 0
          ? '已写入 $written 首的 ReplayGain$average'
          : '已写入 $written 首$average，$failed 首失败（只读或格式不支持写标签）',
    );
  }

  Future<void> _favoriteSelected() async {
    final List<Track> tracks = _selectedTracks;
    if (tracks.isEmpty) {
      return;
    }
    final List<String> paths = tracks.map((Track track) => track.path).toList();
    // 只要还有没收藏的就按「全部收藏」处理，全部已收藏才是取消收藏
    final bool favorite = !_selectionAllFavored;
    final Set<String> previousPaths = Set<String>.of(_favoritePaths);
    final List<Track> previousTracks = _favoriteTracks;

    _update(() {
      if (favorite) {
        _favoritePaths.addAll(paths);
        final Set<String> selected = paths.toSet();
        _favoriteTracks = <Track>[
          ...tracks,
          ..._favoriteTracks.where(
            (Track track) => !selected.contains(track.path),
          ),
        ];
      } else {
        _favoritePaths.removeAll(paths);
        final Set<String> selected = paths.toSet();
        _favoriteTracks = _favoriteTracks
            .where((Track track) => !selected.contains(track.path))
            .toList();
      }
    });

    try {
      await _repository.setFavorites(paths, favorite);
      if (!mounted) {
        return;
      }
      _showMessage(
        favorite ? '已收藏 ${paths.length} 首' : '已取消收藏 ${paths.length} 首',
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      _update(() {
        _favoritePaths = previousPaths;
        _favoriteTracks = previousTracks;
      });
      _showMessage(
        '批量${favorite ? '收藏' : '取消收藏'}失败：${ErrorRetry.describe(error)}',
      );
    }
  }

  Future<void> _addSelectedToPlaylist() async {
    final List<Track> tracks = _selectedTracks;
    if (tracks.isEmpty) {
      return;
    }
    final List<String> paths = tracks.map((Track track) => track.path).toList();
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
        await _createPlaylist(addTrackPaths: paths);
      case PickExistingPlaylist(:final Playlist playlist):
        final int id = playlist.id.toInt();
        try {
          final int added = await _repository.addTracksToPlaylist(id, paths);
          await _loadPlaylists();
          if (_selectedPlaylistId == id) {
            await _loadPlaylistTracks(id);
          }
          if (!mounted) {
            return;
          }
          _showMessage(
            added > 0
                ? '已加入 $added 首到「${playlist.name}」'
                : '「${playlist.name}」里已经有这些曲目',
          );
        } catch (error) {
          if (!mounted) {
            return;
          }
          _showMessage('加入歌单失败：${ErrorRetry.describe(error)}');
        }
    }
  }

  Future<void> _removeSelected() async {
    final List<Track> tracks = _selectedTracks;
    if (tracks.isEmpty) {
      return;
    }
    final bool fromPlaylist = _selectionInPlaylist;
    final int? playlistId = _selectedPlaylistId;
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: Text(
          fromPlaylist
              ? '从歌单移除 ${tracks.length} 首？'
              : '从曲库移除 ${tracks.length} 首？',
        ),
        content: Text(
          fromPlaylist
              ? '只从这个歌单移除，不会删除曲库记录或磁盘上的音频文件。'
              : '只删除曲库记录，不会删除磁盘上的音频文件。',
        ),
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
            child: Text(fromPlaylist ? '移除' : '从曲库移除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      return;
    }

    final Set<String> paths = tracks.map((Track track) => track.path).toSet();
    try {
      if (fromPlaylist && playlistId != null) {
        for (final String path in paths) {
          await _repository.removeTrackFromPlaylist(playlistId, path);
        }
        if (!mounted) {
          return;
        }
        _applyRemovedPaths(paths);
        await _loadPlaylists();
        if (!mounted) {
          return;
        }
        _showMessage('已从歌单移除 ${paths.length} 首');
      } else {
        final int removed = await _repository.removeTracks(paths.toList());
        if (!mounted) {
          return;
        }
        _applyRemovedPaths(paths);
        // 歌单曲目数会跟着变，网格里的数字要重读
        await _loadPlaylists();
        if (!mounted) {
          return;
        }
        _showMessage('已从曲库移除 $removed 首');
      }
      _exitSelection();
    } catch (error) {
      if (!mounted) {
        return;
      }
      _showMessage('移除失败：${ErrorRetry.describe(error)}');
    }
  }

  /// 把已被删除的路径从各本地列表里摘掉。
  ///
  /// 播放队列**不动**：删的是曲库记录，文件还在，正在播放的曲目不该被打断。
  void _applyRemovedPaths(Set<String> removed) {
    if (removed.isEmpty) {
      return;
    }
    _update(() {
      _tracks = _tracks
          .where((Track track) => !removed.contains(track.path))
          .toList();
      _results = _results
          ?.where((Track track) => !removed.contains(track.path))
          .toList();
      _favoriteTracks = _favoriteTracks
          .where((Track track) => !removed.contains(track.path))
          .toList();
      _historyTracks = _historyTracks
          .where((Track track) => !removed.contains(track.path))
          .toList();
      _playlistTracks = _playlistTracks
          .where((Track track) => !removed.contains(track.path))
          .toList();
      _favoritePaths = _favoritePaths.difference(removed);
      _selectedPaths = _selectedPaths.difference(removed);
    });
  }
}

/// 批量计算响度的进度快照
@immutable
class _ReplayGainProgress {
  const _ReplayGainProgress(this.done, this.total, this.title);

  /// 已完成（含失败）的首数
  final int done;
  final int total;

  /// 正在处理 / 刚处理完的曲名
  final String title;
}
