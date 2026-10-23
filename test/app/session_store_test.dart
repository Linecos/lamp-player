import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_player/src/app/session_store.dart';
import 'package:lamp_player/src/features/library/library_sort.dart';
import 'package:lamp_player/src/features/player/playback_queue.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('没有存档时返回默认会话', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final SessionSnapshot snapshot = await const PrefsSessionStore().load();

    expect(snapshot.volume, 1);
    expect(snapshot.lastTrackPath, isNull);
    expect(snapshot.repeat, LoopMode.off);
    expect(snapshot.shuffle, isFalse);
    expect(snapshot.section, isNull);
    expect(snapshot.railExpanded, isTrue);
    expect(snapshot.sort, LibrarySort.library);
    expect(snapshot.coverBackfillAttempted, isFalse, reason: '老用户升级后应触发一次封面补扫');
  });

  test('保存后可以完整读回', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    const PrefsSessionStore store = PrefsSessionStore();

    await store.save(
      const SessionSnapshot(
        volume: 0.35,
        lastVolume: 0.35,
        lastTrackPath: '/music/夜航.mp3',
        lastPositionSecs: 42.5,
        repeat: LoopMode.one,
        shuffle: true,
        section: 'favorites',
        railExpanded: false,
        sort: LibrarySort.added,
        coverBackfillAttempted: true,
      ),
    );

    final SessionSnapshot snapshot = await store.load();
    expect(snapshot.volume, closeTo(0.35, 0.001));
    expect(snapshot.lastVolume, closeTo(0.35, 0.001));
    expect(snapshot.lastTrackPath, '/music/夜航.mp3');
    expect(snapshot.lastPositionSecs, closeTo(42.5, 0.001));
    expect(snapshot.repeat, LoopMode.one);
    expect(snapshot.shuffle, isTrue);
    expect(snapshot.section, 'favorites');
    expect(snapshot.railExpanded, isFalse);
    expect(snapshot.sort, LibrarySort.added);
    expect(snapshot.coverBackfillAttempted, isTrue);
  });

  test('清掉上次曲目与分区后不再残留', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      PrefsSessionStore.lastTrackKey: '/music/夜航.mp3',
      PrefsSessionStore.sectionKey: 'history',
    });
    const PrefsSessionStore store = PrefsSessionStore();

    await store.save(const SessionSnapshot());

    final SessionSnapshot snapshot = await store.load();
    expect(snapshot.lastTrackPath, isNull);
    expect(snapshot.section, isNull);
  });

  test('异常音量读回时被夹到 0~1', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'flutter.${PrefsSessionStore.volumeKey}': 1.8,
    });
    final SessionSnapshot snapshot = await const PrefsSessionStore().load();
    expect(snapshot.volume, 1);
  });

  test('静音退出后仍记得静音前的音量', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    const PrefsSessionStore store = PrefsSessionStore();

    await store.save(const SessionSnapshot(volume: 0, lastVolume: 0.4));

    final SessionSnapshot snapshot = await store.load();
    expect(snapshot.volume, 0, reason: '启动时应保持静音');
    expect(snapshot.lastVolume, closeTo(0.4, 0.001), reason: '取消静音回到 40%');
  });

  test('无法识别的排序方式回退到默认顺序', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'flutter.${PrefsSessionStore.sortKey}': 'unknown',
    });

    final SessionSnapshot snapshot = await const PrefsSessionStore().load();
    expect(snapshot.sort, LibrarySort.library);
  });
}
