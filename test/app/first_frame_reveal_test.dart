import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_player/src/app/first_frame_reveal.dart';

void main() {
  test('首帧光栅化之后才显示窗口', () {
    fakeAsync((FakeAsync async) {
      final Completer<void> rasterized = Completer<void>();
      final List<String> events = <String>[];

      unawaited(
        revealOnFirstFrame(
          rasterized.future,
          onRasterized: () async => events.add('show'),
        ),
      );
      async.flushMicrotasks();
      expect(events, isEmpty, reason: '首帧还没上屏就不该露窗');

      rasterized.complete();
      async.flushMicrotasks();
      expect(events, <String>['show']);
    });
  });

  test('首帧一直等不到时，超时后仍然把窗口显示出来', () {
    fakeAsync((FakeAsync async) {
      final Completer<void> rasterized = Completer<void>();
      final List<String> events = <String>[];

      unawaited(
        revealOnFirstFrame(
          rasterized.future,
          onRasterized: () async => events.add('show'),
          timeout: const Duration(milliseconds: 1500),
        ),
      );
      async.elapse(const Duration(milliseconds: 1400));
      expect(events, isEmpty, reason: '上限之前还要继续等');

      async.elapse(const Duration(milliseconds: 200));
      expect(events, <String>['show'], reason: '窗口不可见时引擎不一定出帧，要有兜底');
    });
  });

  test('显示本身失败也不会把异常抛到外面', () {
    fakeAsync((FakeAsync async) {
      final Completer<void> rasterized = Completer<void>()..complete();

      expect(
        () => unawaited(
          revealOnFirstFrame(
            rasterized.future,
            onRasterized: () async => throw StateError('窗口管理器没起来'),
          ),
        ),
        returnsNormally,
      );
      async.flushMicrotasks();
    });
  });
}
