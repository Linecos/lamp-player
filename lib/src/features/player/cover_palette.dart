import 'dart:collection';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// 从封面缓存文件提取背景配色；按路径做小型 LRU，避免切歌时反复解码。
///
/// 只解码 48×48 缩略图，按 RGB 4bit 分桶统计主色，再挑出彼此有区分度的颜色。
/// 不依赖第三方取色包，解码失败或没有封面时交给主题色兜底。
abstract final class CoverPaletteCache {
  static const int _maxEntries = 24;
  static final LinkedHashMap<String, List<Color>> _cache =
      LinkedHashMap<String, List<Color>>();

  static Future<List<Color>?> load(String? path) async {
    if (path == null || path.isEmpty) {
      return null;
    }
    final List<Color>? cached = _cache.remove(path);
    if (cached != null) {
      _cache[path] = cached;
      return cached;
    }
    final File file = File(path);
    if (!file.existsSync()) {
      return null;
    }

    ui.Codec? codec;
    ui.Image? image;
    try {
      codec = await ui.instantiateImageCodec(
        await file.readAsBytes(),
        targetWidth: 48,
        targetHeight: 48,
      );
      final ui.FrameInfo frame = await codec.getNextFrame();
      image = frame.image;
      final ByteData? bytes = await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      );
      if (bytes == null) {
        return null;
      }

      final Map<int, _Bucket> buckets = <int, _Bucket>{};
      for (int i = 0; i + 3 < bytes.lengthInBytes; i += 4) {
        final int alpha = bytes.getUint8(i + 3);
        if (alpha < 32) {
          continue;
        }
        final int r = bytes.getUint8(i);
        final int g = bytes.getUint8(i + 1);
        final int b = bytes.getUint8(i + 2);
        final int key = ((r >> 4) << 8) | ((g >> 4) << 4) | (b >> 4);
        buckets.putIfAbsent(key, _Bucket.new).add(r, g, b);
      }

      final List<_Bucket> sorted = buckets.values.toList()
        ..sort((_Bucket a, _Bucket b) => b.count.compareTo(a.count));
      final List<Color> colors = <Color>[];
      for (final _Bucket bucket in sorted) {
        final Color color = bucket.color;
        if (colors.any((Color item) => _similar(item, color))) {
          continue;
        }
        colors.add(color);
        // 保留更多候选，供背景层按面积/色相挑选，避免小面积鲜艳色挤掉大面积主色
        if (colors.length >= 6) {
          break;
        }
      }
      if (colors.isEmpty) {
        return null;
      }

      _cache[path] = colors;
      if (_cache.length > _maxEntries) {
        _cache.remove(_cache.keys.first);
      }
      return colors;
    } catch (error) {
      debugPrint('封面取色失败：$error');
      return null;
    } finally {
      image?.dispose();
      codec?.dispose();
    }
  }

  static bool _similar(Color a, Color b) {
    if (_distance(a, b) < 40) {
      return true;
    }
    final HSLColor ha = HSLColor.fromColor(a);
    final HSLColor hb = HSLColor.fromColor(b);
    final double diff = (ha.hue - hb.hue).abs() % 360;
    final double hue = diff > 180 ? 360 - diff : diff;
    return hue < 14 && (ha.lightness - hb.lightness).abs() < 0.16;
  }

  static double _distance(Color a, Color b) {
    final double dr = (a.r - b.r) * 255;
    final double dg = (a.g - b.g) * 255;
    final double db = (a.b - b.b) * 255;
    return math.sqrt(dr * dr + dg * dg + db * db);
  }
}

class _Bucket {
  int count = 0;
  int sumR = 0;
  int sumG = 0;
  int sumB = 0;

  void add(int r, int g, int b) {
    count += 1;
    sumR += r;
    sumG += g;
    sumB += b;
  }

  Color get color => Color.fromARGB(
    255,
    (sumR / count).round(),
    (sumG / count).round(),
    (sumB / count).round(),
  );
}
