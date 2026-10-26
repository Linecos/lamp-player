import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_player/src/features/player/playback_queue.dart';
import 'package:lamp_player/src/features/player/queue_dialog.dart';
import 'package:lamp_player/src/rust/api/model.dart';
import 'package:lamp_player/src/theme/app_theme.dart';

import '../../support/fake_library.dart';

/// 蓝色预设：和用户反馈问题时的配色一致
const Color _seed = Color(0xFF2196F3);

/// 逐个通道比较，允许 2 的误差（圆角 / 抗锯齿边缘可能差一点）
void _expectColor(Color actual, Color expected, {String? reason}) {
  final int a = actual.toARGB32();
  final int e = expected.toARGB32();
  for (int shift = 0; shift <= 16; shift += 8) {
    expect(
      ((a >> shift) & 0xFF) - ((e >> shift) & 0xFF),
      inInclusiveRange(-2, 2),
      reason: reason,
    );
  }
}

Future<Color> _pixelAt(
  WidgetTester tester,
  ValueKey<String> rootKey,
  Offset at,
) async {
  final RenderRepaintBoundary boundary = tester
      .renderObject<RenderRepaintBoundary>(find.byKey(rootKey));
  final ui.Image image =
      (await tester.runAsync(() => boundary.toImage())) as ui.Image;
  final ByteData? data = await tester.runAsync<ByteData?>(
    () => image.toByteData(format: ui.ImageByteFormat.rawRgba),
  );
  final Uint8List bytes = data!.buffer.asUint8List();
  final int x = at.dx.round();
  final int y = at.dy.round();
  final int i = (y * image.width + x) * 4;
  return Color.fromARGB(255, bytes[i], bytes[i + 1], bytes[i + 2]);
}

Future<void> _openQueue(WidgetTester tester, {required int current}) async {
  tester.view.physicalSize = const Size(900, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final PlaybackQueue queue = PlaybackQueue(
    tracks: <Track>[
      for (int i = 0; i < 8; i += 1)
        sampleTrack(title: '曲目 $i', artist: '歌手 $i'),
    ],
    index: current,
  );

  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(_seed),
      builder: (BuildContext context, Widget? child) =>
          RepaintBoundary(key: _rootKey, child: child),
      home: Builder(
        builder: (BuildContext context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () => showPlaybackQueueDialog(
                context,
                queue: queue,
                onChanged: () async {},
              ),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开'));
  await tester.pumpAndSettle();
}

const ValueKey<String> _rootKey = ValueKey<String>('root');

void main() {
  test('弹窗默认把子节点裁到圆角内', () {
    // Flutter 默认是 Clip.none，子节点能画到 28px 圆角外面，露出直角方块
    expect(AppTheme.light(_seed).dialogTheme.clipBehavior, Clip.antiAlias);
    expect(AppTheme.dark(_seed).dialogTheme.clipBehavior, Clip.antiAlias);
  });

  testWidgets('选中行高亮只落在那一行，不会画到弹窗顶部', (WidgetTester tester) async {
    await _openQueue(tester, current: 0);

    final ColorScheme scheme = AppTheme.schemeOf(
      _seed,
      Brightness.light,
      DynamicSchemeVariant.tonalSpot,
    );
    final Color background = scheme.surfaceContainerHigh;
    final Color highlight = Color.alphaBlend(
      scheme.primaryContainer.withValues(alpha: 0.35),
      background,
    );

    final Finder dialogMaterial = find
        .descendant(
          of: find.byKey(const ValueKey<String>('queue-dialog')),
          matching: find.byType(Material),
        )
        .first;
    final Rect dialog = tester.getRect(dialogMaterial);
    final Rect row = tester.getRect(
      find.byKey(const ValueKey<String>('queue-item-0')),
    );

    // 标题区（弹窗顶部 8px、水平居中）只能是弹窗底色。选中行的高亮如果被画到
    // Material 的原点，这里就会变成 primaryContainer 叠出来的蓝灰色方块。
    _expectColor(
      await _pixelAt(
        tester,
        _rootKey,
        Offset(dialog.center.dx, dialog.top + 8),
      ),
      background,
      reason: '弹窗顶部不该出现选中行的高亮色',
    );

    // 高亮本身还在：选中行左侧空白处应该是高亮色
    _expectColor(
      await _pixelAt(tester, _rootKey, Offset(row.left + 12, row.center.dy)),
      highlight,
      reason: '选中行仍要保留高亮底色',
    );

    final AlertDialog dialogWidget = tester.widget<AlertDialog>(
      find.byKey(const ValueKey<String>('queue-dialog')),
    );
    expect(dialogWidget.clipBehavior, Clip.antiAlias);
  });
}
