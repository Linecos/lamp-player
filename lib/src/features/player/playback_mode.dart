import 'package:flutter/material.dart';

import 'playback_queue.dart';

/// 顺序 / 随机 / 列表循环 / 单曲循环的统一图标。
IconData playbackModeIcon(LoopMode repeat, bool shuffle) {
  if (shuffle) {
    return Icons.shuffle;
  }
  return switch (repeat) {
    LoopMode.off => Icons.playlist_play,
    LoopMode.all => Icons.repeat,
    LoopMode.one => Icons.repeat_one,
  };
}

/// 当前播放模式的中文名。
String playbackModeLabel(LoopMode repeat, bool shuffle) {
  if (shuffle) {
    return '随机播放';
  }
  return switch (repeat) {
    LoopMode.off => '顺序播放',
    LoopMode.all => '列表循环',
    LoopMode.one => '单曲循环',
  };
}

/// 是否处于非「顺序播放」状态，用于按钮高亮。
bool playbackModeActive(LoopMode repeat, bool shuffle) {
  return shuffle || repeat != LoopMode.off;
}

/// 在四种状态之间轮换：顺序 → 随机 → 列表循环 → 单曲循环。
///
/// 随机与循环是互斥呈现：从随机再点一次会进入列表循环，而不是同时开启。
void cyclePlayMode(PlaybackQueue queue) {
  if (queue.shuffle) {
    queue.setShuffle(false);
    queue.setRepeat(LoopMode.all);
    return;
  }
  switch (queue.repeat) {
    case LoopMode.off:
      queue.setShuffle(true);
    case LoopMode.all:
      queue.setRepeat(LoopMode.one);
    case LoopMode.one:
      queue.setRepeat(LoopMode.off);
  }
}
