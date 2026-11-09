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
/// [retreat] 返回新下标后真正加载音频。
///
/// **随机模式用「洗牌袋」**：把整轮下标打乱放进 [_shufflePool]，从袋尾依次取出，
/// 取空才重洗——所以一轮之内每首正好放一次，不会出现「某首反复来、某首从不来」。
/// 袋子空了会自动重洗，因此**没有"最后一首"**，可以一直放下去，也不需要
/// [LoopMode] 配合。
///
/// 队列的**显示顺序始终不变**（队列面板按 `tracks` 原序渲染，只高亮当前曲目），
/// 随机只体现在「下一首跳到哪个下标」，所以从列表上推不出后面会放什么。
/// 重洗时会把刚播完的那首和最近听过的几首压到袋首（最后才取到），
/// 避免轮末接轮首时把刚听过的又端上来。
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
       _random = random ?? Random();

  final List<Track> _tracks;
  final Random _random;

  int _index;
  LoopMode _repeat;
  bool _shuffle;

  /// 已经播放过的下标（上一首从这里回退，而不是按列表顺序猜）
  final List<int> _history = <int>[];

  /// 随机模式下"已经抽好、还没播"的那一首。
  ///
  /// [peekNext] 会被连续问好几次（切歌、判定有没有下一首），每次重抽的话
  /// 结果会跳来跳去；抽一次记住，真正切过去之后才清空。
  int? _shuffleNext;

  /// 洗牌袋：一整轮打乱后的下标，从**末尾**取（见 [_pickShuffledNext]）。
  ///
  /// 取空才重洗，所以一轮之内每首正好一次；不需要它的时候保持为空即可。
  /// 队列结构变了（重排 / 删曲 / 插入 / 换队列）要同步维护，否则袋里的下标
  /// 会指向别的歌——这一点比「只在长度变短时剔越界」（ZeroBit 的做法）更严。
  final List<int> _shufflePool = <int>[];

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

  /// 下一首会落在哪里；`null` 表示队列已放完。
  ///
  /// 随机模式（[shuffle]）每次都现抽一首，抽完记住（见 [_shuffleNext]），
  /// 所以只有空队列才会返回 `null`——随机播放没有"最后一首"。
  /// [auto] 为 true 表示“自然播完”，此时单曲循环返回当前下标。
  int? peekNext({bool auto = false}) {
    if (_tracks.isEmpty) {
      return null;
    }
    if (_shuffle) {
      // 随机优先于 LoopMode：选随机的人要的是"一直随机放下去"
      return _shuffleNext ??= _pickShuffledNext();
    }
    if (auto && _repeat == LoopMode.one) {
      return _index;
    }
    if (_index + 1 < _tracks.length) {
      return _index + 1;
    }
    return _repeat == LoopMode.off ? null : 0;
  }

  /// 随机挑一首：从洗牌袋尾部取，取空就重洗一整轮。
  ///
  /// 只在 [advance] 真正切过去时才把这一首从袋里移除，所以 [peekNext]
  /// 连问几次结果都稳定，也不会因为问了一次就少放一首。
  int _pickShuffledNext() {
    final int n = _tracks.length;
    if (n <= 1) {
      return _index < 0 ? 0 : _index;
    }
    if (_shufflePool.isEmpty) {
      _refillShufflePool();
    }
    final int last = _shufflePool.length - 1;
    // 袋尾正好是当前曲目（手动跳回来过）：随手换一个，别原地重播
    if (_shufflePool[last] == _index && last > 0) {
      final int at = _random.nextInt(last);
      final int tmp = _shufflePool[at];
      _shufflePool[at] = _shufflePool[last];
      _shufflePool[last] = tmp;
    }
    return _shufflePool[last];
  }

  /// 重洗一整轮下标。
  ///
  /// 两种「别让人觉得在重复」的小处理，都靠把下标压到袋**首**实现——
  /// 袋尾先播、袋首最后播：
  /// 1. 当前曲目：否则轮末接轮首时会连放两遍同一首；
  /// 2. 最近听过的几首（最多 3 首，且不超过队列的四分之一）：
  ///    免得新一轮开头又把刚听过的端上来。
  ///
  /// 压过去的那一撮内部也打乱，不然「最近听过的」会按固定顺序回放。
  void _refillShufflePool() {
    final int n = _tracks.length;
    final List<int> pool = List<int>.generate(n, (int i) => i)
      ..shuffle(_random);

    final Set<int> deferred = <int>{};
    if (_index >= 0 && _index < n) {
      deferred.add(_index);
    }
    final int guard = min(3, n ~/ 4);
    for (
      int i = _history.length - 1;
      i >= 0 && deferred.length <= guard;
      i -= 1
    ) {
      final int at = _history[i];
      if (at >= 0 && at < n) {
        deferred.add(at);
      }
    }

    final List<int> head =
        pool.where((int index) => deferred.contains(index)).toList()
          ..shuffle(_random);
    final List<int> tail = pool
        .where((int index) => !deferred.contains(index))
        .toList();
    _shufflePool
      ..addAll(head)
      ..addAll(tail);
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
    if (!_shuffle && auto && _repeat == LoopMode.one) {
      return _index;
    }
    final int? next = peekNext(auto: auto);
    if (next == null) {
      return null;
    }
    _pushHistory();
    _index = next;
    // 这一首已经播了：从洗牌袋里摘掉（本轮不再出现）。
    // 袋里没有它也没关系——比如「下一首播放」插进来的那首本来就不在袋里
    if (_shuffle) {
      _shufflePool.remove(next);
    }
    // 抽好的那一首已经播了，下次再抽
    _shuffleNext = null;
    return _index;
  }

  /// 后退一首并返回新下标；返回 `null` 时页面回到曲首。
  int? retreat() {
    if (_tracks.isEmpty) {
      return null;
    }
    if (_history.isNotEmpty) {
      _index = _history.removeLast();
      _shuffleNext = null;
      return _index;
    }
    if (_index > 0) {
      _index -= 1;
      _shuffleNext = null;
      return _index;
    }
    if (_repeat != LoopMode.off) {
      _index = _tracks.length - 1;
      _shuffleNext = null;
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
    if (_shuffle) {
      _shufflePool.remove(index);
    }
    _shuffleNext = null;
    return true;
  }

  /// 用一份新列表替换队列，并从 [index] 开始。
  void reset(List<Track> tracks, {int index = 0}) {
    _tracks
      ..clear()
      ..addAll(tracks);
    _index = tracks.isEmpty ? -1 : index.clamp(0, tracks.length - 1);
    _history.clear();
    _shufflePool.clear();
    _shuffleNext = null;
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
    for (int i = 0; i < _shufflePool.length; i += 1) {
      _shufflePool[i] = remap(_shufflePool[i]);
    }
    // 下标整体平移了，已经抽好的那一首不再可信，重新抽
    _shuffleNext = null;
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
      _shiftShufflePool(removed: index);
    }
    _shuffleNext = null;
    return wasCurrent;
  }

  /// 清空队列；播放由页面负责停下。
  void clear() {
    _tracks.clear();
    _index = -1;
    _history.clear();
    _shufflePool.clear();
    _shuffleNext = null;
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
    // 插在当前曲目之后：它后面的下标整体右移一位，历史和洗牌袋都要跟着挪，
    // 否则「上一首」会跳错歌、袋里也会放重或漏放
    for (int i = 0; i < _history.length; i += 1) {
      if (_history[i] > _index) {
        _history[i] += 1;
      }
    }
    for (int i = 0; i < _shufflePool.length; i += 1) {
      if (_shufflePool[i] > _index) {
        _shufflePool[i] += 1;
      }
    }
    if (_shuffle) {
      // 随机模式下也要让「下一首播放」点得中：把已经抽好的下一首改成它，
      // 否则下次随机又会抽到别处，点了听不到
      _shuffleNext = _index + 1;
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
    _tracks.add(track);
    // 随机模式：「追加到队尾」对应洗牌袋的袋首（最后才取到）。
    // 袋子空着说明这一轮已经放完、马上会重洗，届时它会自然被洗进去
    if (_shuffle && _shufflePool.isNotEmpty) {
      _shufflePool.insert(0, _tracks.length - 1);
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
    // 重新进入随机时不沿用上一轮的袋子：从这一刻起重新洗一轮更符合直觉
    _shufflePool.clear();
    _shuffleNext = null;
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
    _shiftShufflePool(removed: removed);
  }

  /// 删掉某一首之后收拾洗牌袋：指向它的下标要丢掉，比它大的统一左移。
  ///
  /// 不收拾的话袋里的下标会顺移到别的歌上——要么放重、要么漏放，
  /// 而且从界面上完全看不出来（ZeroBit 只在队列变短时剔越界，就有这个问题）。
  void _shiftShufflePool({required int removed}) {
    for (int i = _shufflePool.length - 1; i >= 0; i -= 1) {
      final int at = _shufflePool[i];
      if (at == removed) {
        _shufflePool.removeAt(i);
      } else if (at > removed) {
        _shufflePool[i] = at - 1;
      }
    }
  }
}
