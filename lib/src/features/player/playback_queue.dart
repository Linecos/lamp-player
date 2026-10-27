import 'dart:math';

import '../../rust/api/model.dart';

/// 循环方式。
///
/// `one` 只在“自然播完”时生效；手动点下一首仍会切到下一曲，
/// 否则用户会以为按钮坏了。
enum LoopMode {
  off('不循环'),
  all('列表循环'),
  one('单曲循环');

  const LoopMode(this.label);

  final String label;

  /// 循环方式按 off → all → one → off 轮换
  LoopMode get next => switch (this) {
    LoopMode.off => LoopMode.all,
    LoopMode.all => LoopMode.one,
    LoopMode.one => LoopMode.off,
  };
}

/// 播放队列：曲目顺序 + 下一首 / 上一首规则。
///
/// 只做纯计算，不接触播放器、不依赖 Flutter；页面只负责在 [advance] /
/// [retreat] 返回新下标后真正加载音频。随机播放用一个洗牌顺序推进，
/// 保证一轮内不重复，而不是每次随机抽（会反复听到同一首）。
class PlaybackQueue {
  PlaybackQueue({
    List<Track> tracks = const <Track>[],
    int index = 0,
    LoopMode repeat = LoopMode.off,
    bool shuffle = false,
    Random? random,
  }) : _tracks = List<Track>.of(tracks),
       _index = tracks.isEmpty ? -1 : index.clamp(0, tracks.length - 1),
       _repeat = repeat, // ignore: prefer_initializing_formals
       _shuffle = shuffle, // ignore: prefer_initializing_formals
       _random = random ?? Random() {
    if (_shuffle) {
      _rebuildShuffleOrder();
    }
  }

  final List<Track> _tracks;
  final Random _random;

  int _index;
  LoopMode _repeat;
  bool _shuffle;

  /// 已经播放过的下标（上一首从这里回退，而不是按列表顺序猜）
  final List<int> _history = <int>[];

  /// 随机播放顺序；当前曲目固定在第一位，之后是打乱的其他曲目
  List<int> _shuffleOrder = <int>[];
  int _shufflePos = 0;

  /// 队列快照（只读）；UI 只展示，不直接改
  List<Track> get tracks => List<Track>.unmodifiable(_tracks);

  int get index => _index;

  int get length => _tracks.length;

  bool get isEmpty => _tracks.isEmpty;

  Track? get current =>
      _index >= 0 && _index < _tracks.length ? _tracks[_index] : null;

  LoopMode get repeat => _repeat;

  bool get shuffle => _shuffle;

  bool get hasNext => peekNext() != null;

  bool get hasPrevious => peekPrevious() != null;

  /// 下一首会落在哪里；`null` 表示这一轮已经放完。
  ///
  /// [auto] 为 true 表示“自然播完”，此时单曲循环返回当前下标。
  int? peekNext({bool auto = false}) {
    if (_tracks.isEmpty) {
      return null;
    }
    if (auto && _repeat == LoopMode.one) {
      return _index;
    }
    if (_shuffle) {
      if (_tracks.length == 1) {
        return _repeat == LoopMode.off ? null : 0;
      }
      _ensureShuffleOrder();
      if (_shufflePos + 1 < _shuffleOrder.length) {
        return _shuffleOrder[_shufflePos + 1];
      }
      return _repeat == LoopMode.off ? null : _shuffleOrder[1];
    }
    if (_index + 1 < _tracks.length) {
      return _index + 1;
    }
    return _repeat == LoopMode.off ? null : 0;
  }

  /// 上一首会落在哪里；`null` 表示已到队首且不循环。
  int? peekPrevious() {
    if (_tracks.isEmpty) {
      return null;
    }
    if (_history.isNotEmpty) {
      return _history.last;
    }
    if (_index > 0) {
      return _index - 1;
    }
    return _repeat == LoopMode.off ? null : _tracks.length - 1;
  }

  /// 前进一首并返回新下标。
  ///
  /// 返回 `null` 时不应切歌，页面按“播放结束”处理。
  int? advance({bool auto = false}) {
    if (_tracks.isEmpty) {
      return null;
    }
    // 单曲循环重播同一首，不写历史，避免上一首被自己挤掉
    if (auto && _repeat == LoopMode.one) {
      return _index;
    }
    // 随机播放走到本轮末尾：循环模式重洗一轮，不循环就结束
    if (_shuffle) {
      _ensureShuffleOrder();
    }
    if (_shuffle &&
        _tracks.length > 1 &&
        _shufflePos + 1 >= _shuffleOrder.length) {
      if (_repeat == LoopMode.off) {
        return null;
      }
      _pushHistory();
      _rebuildShuffleOrder();
      _shufflePos = 1;
      _index = _shuffleOrder[1];
      return _index;
    }

    final int? next = peekNext();
    if (next == null) {
      return null;
    }
    _pushHistory();
    _index = next;
    _syncShufflePos();
    return _index;
  }

  /// 后退一首并返回新下标；返回 `null` 时页面回到曲首。
  int? retreat() {
    if (_tracks.isEmpty) {
      return null;
    }
    if (_history.isNotEmpty) {
      _index = _history.removeLast();
      _syncShufflePos();
      return _index;
    }
    if (_index > 0) {
      _index -= 1;
      _syncShufflePos();
      return _index;
    }
    if (_repeat != LoopMode.off) {
      _index = _tracks.length - 1;
      _syncShufflePos();
      return _index;
    }
    return null;
  }

  /// 直接跳到某一首（队列面板点击）。已在当前曲目时返回 false。
  bool jumpTo(int index) {
    if (index < 0 || index >= _tracks.length || index == _index) {
      return false;
    }
    _pushHistory();
    _index = index;
    _syncShufflePos();
    return true;
  }

  /// 用一份新列表替换队列，并从 [index] 开始。
  void reset(List<Track> tracks, {int index = 0}) {
    _tracks
      ..clear()
      ..addAll(tracks);
    _index = tracks.isEmpty ? -1 : index.clamp(0, tracks.length - 1);
    _history.clear();
    if (_shuffle) {
      _rebuildShuffleOrder();
    } else {
      _shuffleOrder = <int>[];
      _shufflePos = 0;
    }
  }

  /// 移除队列里第 [index] 首，返回被移除的是否是当前曲目。
  ///
  /// 移除当前曲目后下标保持原位（后一首顶上来）；若删的是最后一首，
  /// 下标回退到新的队尾。历史里的下标同步左移，避免「上一首」跳错。
  /// 拖动重排：把第 [from] 首挪到第 [to] 位（`to` 为取走该行之后的插入位置）。
  ///
  /// 正在播放的那首跟着自己的下标走，不会因为前面的行被挪动而换歌；
  /// 「上一首」的历史下标一并平移，随机顺序重建。
  void move(int from, int to) {
    if (from < 0 || from >= _tracks.length) {
      return;
    }
    final int target = to.clamp(0, _tracks.length - 1);
    if (target == from) {
      return;
    }
    _tracks.insert(target, _tracks.removeAt(from));
    int remap(int index) {
      if (index == from) {
        return target;
      }
      if (from < target) {
        return index > from && index <= target ? index - 1 : index;
      }
      return index >= target && index < from ? index + 1 : index;
    }

    _index = remap(_index);
    for (int i = 0; i < _history.length; i += 1) {
      _history[i] = remap(_history[i]);
    }
    if (_shuffle) {
      _rebuildShuffleOrder();
    }
  }

  bool removeAt(int index) {
    if (index < 0 || index >= _tracks.length) {
      return false;
    }
    final bool wasCurrent = index == _index;
    _tracks.removeAt(index);
    if (_tracks.isEmpty) {
      _index = -1;
      _history.clear();
    } else {
      if (index < _index) {
        _index -= 1;
      } else if (_index >= _tracks.length) {
        _index = _tracks.length - 1;
      }
      for (int i = _history.length - 1; i >= 0; i -= 1) {
        final int at = _history[i];
        if (at == index) {
          _history.removeAt(i);
        } else if (at > index) {
          _history[i] = at - 1;
        }
      }
    }
    if (_shuffle) {
      _rebuildShuffleOrder();
    }
    return wasCurrent;
  }

  /// 清空队列；播放由页面负责停下。
  void clear() {
    _tracks.clear();
    _index = -1;
    _history.clear();
    _shuffleOrder = <int>[];
    _shufflePos = 0;
  }

  /// 用同一批路径的新曲目对象替换队列里的旧对象（扫描后封面等字段会更新）。
  ///
  /// 只按 `path` 对齐，保持顺序、当前下标与上一首历史不变；新列表里没有的
  /// 曲目保留旧对象，避免扫描失败或文件临时不可读时把队列弄空。
  void refreshTracks(List<Track> tracks) {
    final Map<String, Track> byPath = <String, Track>{
      for (final Track track in tracks) track.path: track,
    };
    for (int i = 0; i < _tracks.length; i += 1) {
      final Track? updated = byPath[_tracks[i].path];
      if (updated != null) {
        _tracks[i] = updated;
      }
    }
  }

  /// 插入到当前曲目之后；同一路径已在队列里时先挪过来，避免重复。
  bool insertNext(Track track) {
    if (_tracks.isEmpty) {
      reset(<Track>[track]);
      return true;
    }
    if (track.path == current?.path) {
      return false;
    }
    _removePath(track.path);
    _tracks.insert(_index + 1, track);
    if (_shuffle) {
      // 随机模式下重建顺序时把刚插入的曲目固定在当前曲之后，
      // 否则「下一首播放」会被洗牌打乱，点了却听不到。
      _rebuildShuffleOrder(playNext: _index + 1);
    }
    return true;
  }

  /// 追加到队尾；同一路径已在队列里时不重复添加。
  bool append(Track track) {
    if (_tracks.isEmpty) {
      reset(<Track>[track]);
      return true;
    }
    if (track.path == current?.path ||
        _tracks.any((Track t) => t.path == track.path)) {
      return false;
    }
    if (_shuffle) {
      // 先对齐现有顺序，再把新曲目放到随机顺序末尾，避免追加一首就重洗整轮
      _ensureShuffleOrder();
    }
    _tracks.add(track);
    if (_shuffle) {
      _shuffleOrder.add(_tracks.length - 1);
    }
    return true;
  }

  void setRepeat(LoopMode mode) {
    _repeat = mode;
  }

  void setShuffle(bool value) {
    if (_shuffle == value) {
      return;
    }
    _shuffle = value;
    if (value) {
      _rebuildShuffleOrder();
    } else {
      _shuffleOrder = <int>[];
      _shufflePos = 0;
    }
  }

  /// 重新生成随机顺序：当前曲目固定在第一位，其余打乱。
  ///
  /// [playNext] 用于「下一首播放」：把指定下标固定在当前曲目之后，
  /// 这样随机模式下点「下一首播放」也一定先播它。
  void _rebuildShuffleOrder({int? playNext}) {
    final List<int> order = List<int>.generate(_tracks.length, (int i) => i);
    final int? current = _index >= 0 && _index < _tracks.length ? _index : null;
    final bool hasPlayNext =
        playNext != null &&
        playNext != current &&
        playNext >= 0 &&
        playNext < _tracks.length;

    if (current != null) {
      order.remove(current);
    }
    if (hasPlayNext) {
      order.remove(playNext);
    }
    order.shuffle(_random);
    if (hasPlayNext) {
      order.insert(0, playNext);
    }
    if (current != null) {
      order.insert(0, current);
    }
    _shuffleOrder = order;
    _shufflePos = 0;
  }

  /// 索引可能因增删而漂移；长度或位置不一致时重建，保证随机顺序始终有效。
  void _ensureShuffleOrder() {
    if (!_shuffle) {
      return;
    }
    if (_shuffleOrder.length != _tracks.length ||
        _shufflePos >= _shuffleOrder.length ||
        _shuffleOrder[_shufflePos] != _index) {
      _rebuildShuffleOrder();
    }
  }

  void _syncShufflePos() {
    if (!_shuffle) {
      return;
    }
    final int pos = _shuffleOrder.indexOf(_index);
    if (pos >= 0) {
      _shufflePos = pos;
    } else {
      _rebuildShuffleOrder();
    }
  }

  void _pushHistory() {
    if (_index < 0 || (_history.isNotEmpty && _history.last == _index)) {
      return;
    }
    _history.add(_index);
    if (_history.length > 200) {
      _history.removeAt(0);
    }
  }

  /// 移除同路径曲目；索引与历史里比它大的下标要一起左移。
  ///
  /// 历史里正好等于 [removed] 的那条要删掉而不是减一：它代表“刚移走的那首”，
  /// 减一后指向的是被左移挤过来的另一首，退回上一首就会重播当前曲。
  void _removePath(String path) {
    final int removed = _tracks.indexWhere((Track t) => t.path == path);
    if (removed < 0) {
      return;
    }
    _tracks.removeAt(removed);
    if (removed < _index) {
      _index -= 1;
    }
    for (int i = _history.length - 1; i >= 0; i -= 1) {
      final int at = _history[i];
      if (at == removed) {
        _history.removeAt(i);
      } else if (at > removed) {
        _history[i] = at - 1;
      }
    }
  }
}
