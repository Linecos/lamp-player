import 'dart:async';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_player/src/common/ui_clock.dart';
import 'package:lamp_player/src/features/player/spectrum_controller.dart';

Float32List _frame(double value) =>
    Float32List.fromList(List<double>.filled(24, value));

/// 频谱帧要等下一个 30fps 时钟跳才画出去
void _tick(FakeAsync async) => async.elapse(UiClock.interval);

/// 假的数据源：每次 open 都记下来，测试自己往里推帧
class _Source {
  final List<StreamController<Float32List>> opened =
      <StreamController<Float32List>>[];

  int get count => opened.length;

  Stream<Float32List> open() {
    final StreamController<Float32List> controller =
        StreamController<Float32List>();
    opened.add(controller);
    return controller.stream;
  }

  StreamController<Float32List> get last => opened.last;
}

void main() {
  test('收到帧后上升跟随、回落变慢', () {
    fakeAsync((FakeAsync async) {
      final _Source source = _Source();
      final SpectrumController controller = SpectrumController.withSource(
        source.open,
      );
      controller.attach();
      async.flushMicrotasks();
      expect(source.count, 1);

      source.last.add(_frame(0.8));
      async.flushMicrotasks();
      _tick(async);
      final double risen = controller.bands.value.first;
      expect(risen, greaterThan(0.4));

      source.last.add(_frame(0));
      async.flushMicrotasks();
      _tick(async);
      final double fallen = controller.bands.value.first;
      expect(fallen, lessThan(risen));
      // 只回落一小步（release 系数），不是直接掉到 0
      expect(fallen, greaterThan(risen * 0.55));

      controller.detach();
      async.flushMicrotasks();
      expect(controller.bands.value, isEmpty);
      expect(controller.isListening, isFalse);
      expect(controller.isPolling, isFalse);
    });
  });

  test('数据流报错后自动重连，不会一直空着', () {
    fakeAsync((FakeAsync async) {
      final _Source source = _Source();
      int calls = 0;
      final SpectrumController controller = SpectrumController.withSource(() {
        calls += 1;
        if (calls == 1) {
          return Stream<Float32List>.error(StateError('引擎还没起来'));
        }
        return source.open();
      });
      controller.attach();
      async.flushMicrotasks();
      expect(calls, 1);

      // 退避 400ms 后自己再拉一条
      async.elapse(const Duration(milliseconds: 500));
      expect(calls, 2);

      source.last.add(_frame(0.5));
      async.flushMicrotasks();
      _tick(async);
      expect(controller.bands.value, isNotEmpty);

      controller.detach();
      async.flushMicrotasks();
    });
  });

  test('流不再出帧时看门狗换一条新的', () {
    fakeAsync((FakeAsync async) {
      final _Source source = _Source();
      final SpectrumController controller = SpectrumController.withSource(
        source.open,
      );
      controller.attach();
      async.flushMicrotasks();
      // 先出一帧，把「没有有效帧就改轮询」的兜底解除
      source.last.add(_frame(0.4));
      async.flushMicrotasks();
      expect(source.count, 1);
      expect(controller.isPolling, isFalse);

      // 3 秒没有任何帧：超过 stallTimeout 就该重连
      async.elapse(const Duration(seconds: 3));
      expect(source.count, 2);

      controller.detach();
      async.flushMicrotasks();
      // 退订后看门狗也停：再等一段时间不会多开流
      final int settled = source.count;
      async.elapse(const Duration(seconds: 5));
      expect(source.count, settled);
    });
  });

  test('流一直不出帧时退化成轮询', () {
    fakeAsync((FakeAsync async) {
      final _Source source = _Source();
      int samples = 0;
      final SpectrumController controller = SpectrumController.withSource(
        () => source.open(),
        sample: () async {
          samples += 1;
          return _frame(0.6);
        },
      );
      controller.attach();
      async.flushMicrotasks();
      expect(controller.isPolling, isFalse);

      // 宽限期一过：一帧有效数据都没有，改轮询
      async.elapse(SpectrumController.streamGrace);
      expect(controller.isPolling, isTrue);
      async.elapse(SpectrumController.pollInterval * 3);
      expect(samples, greaterThan(1));
      expect(controller.bands.value, isNotEmpty);
      expect(controller.bands.value.first, greaterThan(0.2));

      controller.detach();
      async.flushMicrotasks();
      expect(controller.bands.value, isEmpty);
      final int settled = samples;
      async.elapse(const Duration(seconds: 2));
      expect(samples, settled, reason: '退订后应停止轮询');
    });
  });

  test('重复 attach 只开一条流，最后一个 detach 才停', () {
    fakeAsync((FakeAsync async) {
      final _Source source = _Source();
      final SpectrumController controller = SpectrumController.withSource(
        source.open,
      );
      controller.attach();
      controller.attach();
      async.flushMicrotasks();
      expect(source.count, 1);

      controller.detach();
      async.flushMicrotasks();
      expect(controller.isListening, isTrue);

      controller.detach();
      async.flushMicrotasks();
      expect(controller.isListening, isFalse);
      expect(controller.bands.value, isEmpty);
    });
  });
}
