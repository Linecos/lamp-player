import 'package:flutter/painting.dart';
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
}
