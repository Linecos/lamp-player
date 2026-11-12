import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

/// ImageFilter 缓存类
///
/// 全局静态缓存，sigma 量化到 0.1 步长以减少缓存条目。
///
/// 步长不能再放粗：调用方给的是调出来的数值（0.5 / 1.1 / 1.8 / 2.5 / 3.2），
/// 按 0.5 量化会把 1.1 变成 1.0、3.2 变成 3.0，模糊的层次感就变了。
class ImageFilterCache {
  const ImageFilterCache._();

  static final Map<int, ui.ImageFilter> _blurCache = <int, ui.ImageFilter>{};

  /// 缓存上限
  static const int _maxBlurCacheSize = 32;

  /// 带缓存的 [ui.ImageFilter.blur]。
  /// sigma 会被量化到 0.1 的步长
  static ui.ImageFilter imageFilter({
    required double sigma,
    ui.TileMode tileMode = ui.TileMode.clamp,
  }) {
    final int quantized = (sigma * 10).round();
    final int key = (quantized << 4) | tileMode.index;

    final ui.ImageFilter? cached = _blurCache[key];
    if (cached != null) return cached;

    if (_blurCache.length >= _maxBlurCacheSize) _blurCache.clear();

    final ui.ImageFilter filter = ui.ImageFilter.blur(
      sigmaX: sigma,
      sigmaY: sigma,
      tileMode: tileMode,
    );
    _blurCache[key] = filter;
    return filter;
  }

  /// 释放缓存
  static void clear() => _blurCache.clear();
}

/// 按 (矩形尺寸 + 渐变参数) 缓存 [ui.Shader]。
class GradientShaderCache {
  GradientShaderCache({this.maxSize = 20});

  final int maxSize;
  final Map<_ShaderKey, ui.Shader> _cache = <_ShaderKey, ui.Shader>{};

  ui.Shader shader({required Gradient gradient, required ui.Rect rect}) {
    final _ShaderKey key = _ShaderKey(gradient, rect);

    final ui.Shader? cached = _cache[key];
    if (cached != null) {
      // LRU: 移到最后
      _cache.remove(key);
      _cache[key] = cached;
      return cached;
    }

    // 缓存满时移除最旧的
    while (_cache.length >= maxSize) {
      final _ShaderKey oldest = _cache.keys.first;
      _cache.remove(oldest)?.dispose();
    }

    final ui.Shader created = gradient.createShader(rect);
    _cache[key] = created;
    return created;
  }

  void clear() {
    for (final ui.Shader s in _cache.values) {
      s.dispose();
    }
    _cache.clear();
  }
}

class _ShaderKey {
  const _ShaderKey(this.gradient, this.rect);

  final Gradient gradient;
  final ui.Rect rect;

  @override
  bool operator ==(Object other) =>
      other is _ShaderKey && other.rect == rect && other.gradient == gradient;

  @override
  int get hashCode => Object.hash(gradient, rect);
}
