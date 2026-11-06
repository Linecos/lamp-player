import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_player/src/app/image_cache_config.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('封面缓存上限比 Flutter 默认的 100MB 更紧', () {
    final ImageCache cache = PaintingBinding.instance.imageCache;
    final int oldSize = cache.maximumSize;
    final int oldBytes = cache.maximumSizeBytes;
    addTearDown(() {
      cache.maximumSize = oldSize;
      cache.maximumSizeBytes = oldBytes;
    });

    configureImageCache();

    expect(cache.maximumSize, coverCacheMaxEntries);
    expect(cache.maximumSizeBytes, coverCacheMaxBytes);
    expect(coverCacheMaxBytes, lessThan(100 << 20));
    expect(coverCacheMaxEntries, lessThan(1000));
  });

  testWidgets('trimImageCache 会放掉已解码的图（live 那份也算）', (
    WidgetTester tester,
  ) async {
    // 1×1 透明 PNG：足够让 ImageCache 里留下一条解码结果
    final Uint8List pixel = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGA'
      'hKmMIQAAAABJRU5ErkJggg==',
    );
    await tester.pumpWidget(
      MaterialApp(home: Image.memory(pixel, width: 1, height: 1)),
    );
    await tester.pumpAndSettle();

    final ImageCache cache = PaintingBinding.instance.imageCache;
    expect(
      cache.liveImageCount + cache.currentSize,
      greaterThan(0),
      reason: '先确认这张图确实进了缓存',
    );

    trimImageCache();

    expect(cache.currentSize, 0, reason: 'keepAlive 缓存要清空');
    expect(cache.liveImageCount, 0, reason: '正在被 widget 引用的那份也要放掉，否则内存只涨不降');
  });
}
