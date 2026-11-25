import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_player/src/app/taskbar_thumbnail.dart';

/// 任务栏缩略图工具栏的 Dart 侧：只验通道的两头（推状态 / 收点击），
/// 原生侧的 ITaskbarList3 只能真机看。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel channel = MethodChannel('lamp_player/taskbar');
  const StandardMethodCodec codec = StandardMethodCodec();

  final List<MethodCall> calls = <MethodCall>[];

  void installChannel() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          calls.add(call);
          return null;
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });
  }

  /// 模拟原生侧发一条 `onButtonClick` 上来
  Future<void> fakeClick(String action) {
    return TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          channel.name,
          codec.encodeMethodCall(MethodCall('onButtonClick', action)),
          (ByteData? _) {},
        );
  }

  test('没注册回调时不打扰原生侧', () async {
    installChannel();
    await TaskbarThumbnail.setButtons(isPlaying: false, visible: false);
    expect(calls, isEmpty, reason: '测试宿主里没有原生侧，连调用都不该发');
  });

  test('注册后把播放状态推给原生侧', () async {
    installChannel();
    TaskbarThumbnail.init(onButtonClick: (TaskbarButtonAction _) {});

    await TaskbarThumbnail.setButtons(isPlaying: true);
    expect(calls.single.method, 'setButtons');
    expect(calls.single.arguments, <String, Object>{
      'isPlaying': true,
      'visible': true,
    });

    calls.clear();
    await TaskbarThumbnail.setButtons(isPlaying: false, visible: false);
    expect(calls.single.arguments, <String, Object>{
      'isPlaying': false,
      'visible': false,
    });
  });

  test('原生侧点按钮转成动作', () async {
    installChannel();
    final List<TaskbarButtonAction> actions = <TaskbarButtonAction>[];
    TaskbarThumbnail.init(onButtonClick: actions.add);

    await fakeClick('prev');
    await fakeClick('toggle');
    await fakeClick('next');

    expect(actions, <TaskbarButtonAction>[
      TaskbarButtonAction.prev,
      TaskbarButtonAction.toggle,
      TaskbarButtonAction.next,
    ]);
  });

  test('封面上传 / 撤回也走同一条通道', () async {
    installChannel();
    TaskbarThumbnail.init(onButtonClick: (TaskbarButtonAction _) {});

    final Uint8List bytes = Uint8List.fromList(<int>[1, 2, 3]);
    await TaskbarThumbnail.setCover(bytes);
    expect(calls.single.method, 'setCover');
    expect(
      (calls.single.arguments as Map<Object?, Object?>)['bytes'],
      bytes,
      reason: '原样把封面字节交给原生侧解码',
    );

    calls.clear();
    await TaskbarThumbnail.clearCover();
    expect(calls.single.method, 'clearCover');
  });

  test('空字节不打扰原生侧', () async {
    installChannel();
    TaskbarThumbnail.init(onButtonClick: (TaskbarButtonAction _) {});

    await TaskbarThumbnail.setCover(Uint8List(0));
    expect(calls, isEmpty);
  });

  test('不认识的方法名不炸', () async {
    installChannel();
    final List<TaskbarButtonAction> actions = <TaskbarButtonAction>[];
    TaskbarThumbnail.init(onButtonClick: actions.add);

    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          channel.name,
          codec.encodeMethodCall(const MethodCall('somethingElse')),
          (ByteData? _) {},
        );

    expect(actions, isEmpty);
  });
}
