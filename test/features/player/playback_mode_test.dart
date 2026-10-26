import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_player/src/features/player/playback_mode.dart';
import 'package:lamp_player/src/features/player/playback_queue.dart';

import '../../support/fake_library.dart';

void main() {
  test('cyclePlayMode 在顺序、随机、列表循环、单曲循环之间轮换', () {
    final PlaybackQueue queue = PlaybackQueue(
      tracks: <dynamic>[sampleTrack(title: '夜航')].cast(),
    );

    expect(queue.repeat, LoopMode.off);
    expect(queue.shuffle, isFalse);
    expect(playbackModeLabel(queue.repeat, queue.shuffle), '顺序播放');

    cyclePlayMode(queue);
    expect(queue.shuffle, isTrue);
    expect(queue.repeat, LoopMode.off);
    expect(playbackModeLabel(queue.repeat, queue.shuffle), '随机播放');

    cyclePlayMode(queue);
    expect(queue.shuffle, isFalse);
    expect(queue.repeat, LoopMode.all);
    expect(playbackModeLabel(queue.repeat, queue.shuffle), '列表循环');

    cyclePlayMode(queue);
    expect(queue.shuffle, isFalse);
    expect(queue.repeat, LoopMode.one);
    expect(playbackModeLabel(queue.repeat, queue.shuffle), '单曲循环');

    cyclePlayMode(queue);
    expect(queue.repeat, LoopMode.off);
    expect(queue.shuffle, isFalse);
  });
}
