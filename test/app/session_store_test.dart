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
    expect(snapshot.flowBackground, isTrue, reason: '默认开启流光背景');
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
        sort: LibrarySort.title,
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
    expect(snapshot.sort, LibrarySort.title);
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

  test('「最近添加」仍能被存档解析', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'flutter.${PrefsSessionStore.sortKey}': 'added',
    });

    final SessionSnapshot snapshot = await const PrefsSessionStore().load();
    expect(snapshot.sort, LibrarySort.added);
  });

  test('流光背景偏好可以存取', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    const PrefsSessionStore store = PrefsSessionStore();

    await store.save(const SessionSnapshot(flowBackground: false));
    expect((await store.load()).flowBackground, isFalse);

    await store.save(const SessionSnapshot(flowBackground: true));
    expect((await store.load()).flowBackground, isTrue);
  });

  test('独占输出偏好可以存取', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    const PrefsSessionStore store = PrefsSessionStore();

    await store.save(const SessionSnapshot(exclusiveOutput: true));

    final SessionSnapshot snapshot = await store.load();
    expect(snapshot.exclusiveOutput, isTrue);
  });

  test('均衡器开关与各段增益可以存取', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    const PrefsSessionStore store = PrefsSessionStore();

    await store.save(
      const SessionSnapshot(
        eqEnabled: true,
        eqGains: <double>[1.5, -2.5, 0, 0, 0, 3, 0, 0, -1, 0],
      ),
    );

    final SessionSnapshot snapshot = await store.load();
    expect(snapshot.eqEnabled, isTrue);
    expect(snapshot.eqGains, <double>[1.5, -2.5, 0, 0, 0, 3, 0, 0, -1, 0]);
  });

  _volumeCurveMigrationTests();
}

/// 音量曲线从「滑块值=振幅」升级到三次曲线后，老存档要按等响度搬过来，
/// 否则同一个滑块值会突然安静 12 dB（用户以为音量丢了）。
void _volumeCurveMigrationTests() {
  test('老存档的音量按立方根迁移，且只迁移一次', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      PrefsSessionStore.volumeKey: 0.5,
      PrefsSessionStore.lastVolumeKey: 0.8,
    });
    const PrefsSessionStore store = PrefsSessionStore();

    final SessionSnapshot first = await store.load();
    expect(first.volume, closeTo(0.7937, 0.001), reason: 'cbrt(0.5)≈0.794');
    expect(first.lastVolume, closeTo(0.9283, 0.001), reason: 'cbrt(0.8)≈0.928');

    final SharedPreferences prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getInt(PrefsSessionStore.volumeCurveVersionKey),
      PrefsSessionStore.volumeCurveVersion,
      reason: '迁移后要立刻落版本号，否则每次启动都会再搬一次',
    );

    // 第二次读不能再次取立方根
    final SessionSnapshot second = await store.load();
    expect(second.volume, closeTo(first.volume, 0.0001));
  });

  test('已经是新曲线的存档原样读出', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      PrefsSessionStore.volumeKey: 0.5,
      PrefsSessionStore.volumeCurveVersionKey:
          PrefsSessionStore.volumeCurveVersion,
    });

    final SessionSnapshot snapshot = await const PrefsSessionStore().load();
    expect(snapshot.volume, 0.5);
  });

  test('保存时写入曲线版本', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await const PrefsSessionStore().save(const SessionSnapshot(volume: 0.3));

    final SharedPreferences prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getInt(PrefsSessionStore.volumeCurveVersionKey),
      PrefsSessionStore.volumeCurveVersion,
    );
  });
}
