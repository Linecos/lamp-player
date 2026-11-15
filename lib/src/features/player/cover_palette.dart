import 'dart:collection';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:material_color_utilities/material_color_utilities.dart';

/// 一张封面的取色结果。
///
/// 两件事一次算完、一起缓存：给流光背景用的 [colors]（按面积），和给动态主题
/// 用的 [seed]（按 Material 官方打分）。分开是因为**两者要的颜色不一样**——
/// 背景要「面积大、有区分度」，主题要「够艳、够亮」，取面积最大的那个当主题色
/// 经常拿到深藏青或近白，整界面就灰了。
class _Palette {
  const _Palette(this.colors, this.seed);

  final List<Color> colors;

  /// 适合当主题种子的颜色；封面色调太灰 / 太暗 / 太亮时为 `null`（不换主题）
  final Color? seed;
}

/// 从封面缓存文件提取背景配色；按路径做小型 LRU，避免切歌时反复解码。
///
/// 只解码 48×48 缩略图，按 RGB 4bit 分桶统计主色，再挑出彼此有区分度的颜色。
/// 解码失败或没有封面时交给主题色兜底。
abstract final class CoverPaletteCache {
  static const int _maxEntries = 24;
  static final LinkedHashMap<String, _Palette> _cache =
      LinkedHashMap<String, _Palette>();

  /// 当前缓存了多少条（内存日志用）
  static int get length => _cache.length;

  /// 流光背景用：按面积排好、彼此有区分度的一串颜色
  static Future<List<Color>?> load(String? path) async =>
      (await _entry(path))?.colors;

  /// 动态主题用：从同一份统计里挑出的「适合当 seed」的颜色
  static Future<Color?> loadSeed(String? path) async =>
      (await _entry(path))?.seed;

  static Future<_Palette?> _entry(String? path) async {
    if (path == null || path.isEmpty) {
      return null;
    }
    final _Palette? cached = _cache.remove(path);
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
    ui.ImmutableBuffer? buffer;
    ui.ImageDescriptor? descriptor;
    try {
      // 不要 `file.readAsBytes()`：封面缓存里常有 1~5MB 的原图，为了取一张
      // 48×48 的缩略图把整份字节读进 Dart 堆，等于每换一首歌就多扔一份几 MB
      // 的临时缓冲（还要跨一个 await，minor GC 收不掉）。`fromFilePath` 只
      // 把文件映射进来，解码缩放交给引擎。
      buffer = await ui.ImmutableBuffer.fromFilePath(path);
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      codec = await descriptor.instantiateCodec(
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

      // 主题种子用「颜色 → 像素数」的原始统计，不是上面那串去重后的颜色：
      // 打分要的是「这个颜色在画面里占多少」，而不是「排第几」
      final Map<int, int> counts = <int, int>{
        for (final MapEntry<int, _Bucket> entry in buckets.entries)
          entry.value.color.toARGB32(): entry.value.count,
      };
      final _Palette palette = _Palette(colors, pickCoverSeed(counts));
      _cache[path] = palette;
      if (_cache.length > _maxEntries) {
        _cache.remove(_cache.keys.first);
      }
      return palette;
    } catch (error) {
      debugPrint('封面取色失败：$error');
      return null;
    } finally {
      image?.dispose();
      codec?.dispose();
      descriptor?.dispose();
      buffer?.dispose();
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

  /// 从「颜色 → 像素数」里挑一个适合当主题种子的颜色；挑不出就返回 `null`。
  ///
  /// 打分直接用 Material 官方的 [Score]（`ColorScheme.fromSeed` 用的也是它）：
  /// 按「在画面里的占比」和「彩度」加权，再把候选按色相拉开距离。**不能用面积
  /// 最大的那个**——实测常见封面的主色是深藏青、近白、灰蓝，拿它当 seed 生成
  /// 出来是一片灰，等于没换主题。
  ///
  /// 这里关掉 [Score] 自带的 `filter`：它滤完可能一个不剩、直接退回一个固定的
  /// 蓝色，灰封面就会突然变成蓝主题。门槛改由 [_usableAsSeed] 自己判，判不出来
  /// 就「不换」，保持上一个颜色。
  @visibleForTesting
  static Color? pickCoverSeed(Map<int, int> counts) {
    if (counts.isEmpty) {
      return null;
    }
    for (final int argb in Score.score(counts, desired: 8, filter: false)) {
      final Hct hct = Hct.fromInt(argb);
      if (_usableAsSeed(hct)) {
        return Color(argb);
      }
    }
    return null;
  }

  /// 这个颜色当 seed 能不能用。
  ///
  /// - **彩度太低**（灰、白、黑）：MD3 从低彩度 seed 生成出来还是一套灰调，
  ///   换了等于没换，不如保留上一次的颜色
  /// - **太暗 / 太亮**：深色主题下主色会和背景糊在一起，浅色主题下会发白
  ///
  /// 阈值按 HCT 的 chroma / tone（0~100）给：chroma ≥ 24 大约相当于「一眼能看出
  /// 是什么颜色」，tone 25~90 正好排掉纯黑与纯白两头。
  static bool _usableAsSeed(Hct hct) =>
      hct.chroma >= 24 && hct.tone >= 25 && hct.tone <= 90;
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
