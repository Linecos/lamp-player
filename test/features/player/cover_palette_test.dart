import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_player/src/features/player/cover_palette.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('从封面提取多种颜色并命中缓存', () async {
    final Directory dir = Directory.systemTemp.createTempSync('lamp-palette');
    addTearDown(() => dir.deleteSync(recursive: true));
    final File cover = File('${dir.path}/cover.png');
    cover.writeAsBytesSync(
      base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAIAAAD8GO2jAAAAQUlEQVR4nO3QMQ0A'
        'MAzEwDQYCiI4irTAAqYQrAzdfPNLL3l1VUycfUf7jM/SA2IiZCJkImQiZCJkImQi'
        'ZCJkoiAPO+cCYtEmhBcAAAAASUVORK5CYII=',
      ),
    );

    final List<Color>? first = await CoverPaletteCache.load(cover.path);
    expect(first, isNotNull);
    expect(first!.length, greaterThanOrEqualTo(2));

    final List<Color>? second = await CoverPaletteCache.load(cover.path);
    expect(identical(first, second), isTrue, reason: '同一路径应命中缓存');
  });

  test('纯色封面也能取色，不会退回主题色', () async {
    final Directory dir = Directory.systemTemp.createTempSync('lamp-solid');
    addTearDown(() => dir.deleteSync(recursive: true));
    final File cover = File('${dir.path}/solid.png');
    cover.writeAsBytesSync(
      base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAIAAAD8GO2jAAAAPElEQVR4nO3RQREAMAjE'
        'wKNC+q5/FciqhPDhlxVwzITq+7LprK7HAwP+AJkImQiZCJkImQiZCJkImSjkA1k2AU5l'
        'vhVGAAAAAElFTkSuQmCC',
      ),
    );

    final List<Color>? colors = await CoverPaletteCache.load(cover.path);
    expect(colors, isNotNull);
    expect(colors, isNotEmpty);
    expect(colors!.first.r, greaterThan(0.6), reason: '应取到封面的红色');
  });

  test('没有封面或文件不存在时返回 null', () async {
    expect(await CoverPaletteCache.load(null), isNull);
    expect(await CoverPaletteCache.load(''), isNull);
    expect(await CoverPaletteCache.load('/missing/cover.jpg'), isNull);
  });

  group('主题种子选色', () {
    test('大面积深藏青 + 一小块品红时选品红', () {
      // 真实封面最常见的构图：暗色大面积底 + 一小块鲜艳主体。
      // 取面积最大的那个当 seed，生成出来是一片灰，等于没换主题。
      final Color? seed = CoverPaletteCache.pickCoverSeed(<int, int>{
        const Color(0xFF1A264E).toARGB32(): 1800,
        const Color(0xFF455A7D).toARGB32(): 300,
        const Color(0xFFE91E63).toARGB32(): 120,
      });
      expect(seed, isNotNull);
      expect(seed, isNot(const Color(0xFF1A264E)));
      final HSLColor picked = HSLColor.fromColor(seed!);
      final HSLColor pink = HSLColor.fromColor(const Color(0xFFE91E63));
      expect((picked.hue - pink.hue).abs(), lessThan(25));
    });

    test('灰阶封面挑不出种子色', () {
      expect(
        CoverPaletteCache.pickCoverSeed(<int, int>{
          const Color(0xFF000000).toARGB32(): 1200,
          const Color(0xFFFFFFFF).toARGB32(): 900,
          const Color(0xFF808080).toARGB32(): 600,
        }),
        isNull,
        reason: '灰阶封面应该「不换」，保持上一个主题色',
      );
    });

    test('太暗的饱和色当不了种子', () {
      // 有彩度但 tone 太低：深色主题下主色会和背景糊在一起
      expect(
        CoverPaletteCache.pickCoverSeed(<int, int>{
          const Color(0xFF120A2E).toARGB32(): 2000,
        }),
        isNull,
      );
    });

    test('没有像素时返回 null', () {
      expect(CoverPaletteCache.pickCoverSeed(<int, int>{}), isNull);
    });

    test('同一色相被拆成多个分桶时仍能选中', () {
      // 分桶按 4bit 做，一块渐变会拆成好几个相邻颜色
      final Color? seed = CoverPaletteCache.pickCoverSeed(<int, int>{
        const Color(0xFF7B1FA2).toARGB32(): 200,
        const Color(0xFF8E24AA).toARGB32(): 200,
        const Color(0xFF9C27B0).toARGB32(): 200,
        const Color(0xFF6A1B9A).toARGB32(): 200,
        const Color(0xFFEDEDED).toARGB32(): 1000,
      });
      expect(seed, isNotNull);
      expect(HSLColor.fromColor(seed!).saturation, greaterThan(0.3));
    });
  });

  group('从真实 PNG 取色', () {
    late Directory dir;

    setUpAll(() {
      dir = Directory.systemTemp.createTempSync('lamp-seed');
    });

    tearDownAll(() {
      if (dir.existsSync()) {
        dir.deleteSync(recursive: true);
      }
    });

    /// 画一张「大面积底色 + 右下角一小块强调色」的 PNG
    Future<String> makeCover(
      String name,
      Color background,
      Color accent,
    ) async {
      const double size = 120;
      final ui.PictureRecorder recorder = ui.PictureRecorder();
      final Canvas canvas = Canvas(recorder);
      canvas.drawRect(
        const Rect.fromLTWH(0, 0, size, size),
        Paint()..color = background,
      );
      canvas.drawRect(
        const Rect.fromLTWH(size * 0.68, size * 0.68, size * 0.32, size * 0.32),
        Paint()..color = accent,
      );
      final ui.Image image = await recorder.endRecording().toImage(
        size.toInt(),
        size.toInt(),
      );
      final ByteData? data = await image.toByteData(
        format: ui.ImageByteFormat.png,
      );
      image.dispose();
      final File file = File('${dir.path}/$name.png');
      file.writeAsBytesSync(data!.buffer.asUint8List());
      return file.path;
    }

    test('同一张封面：流光用面积最大的色，主题用那块鲜艳的色', () async {
      final String path = await makeCover(
        'navy_pink',
        const Color(0xFF1A264E),
        const Color(0xFFE91E63),
      );

      final List<Color>? colors = await CoverPaletteCache.load(path);
      expect(colors, isNotNull);
      final HSLColor dominant = HSLColor.fromColor(colors!.first);
      final HSLColor navy = HSLColor.fromColor(const Color(0xFF1A264E));
      expect(dominant.hue, closeTo(navy.hue, 30), reason: '背景层要的是面积最大的那个');

      final Color? seed = await CoverPaletteCache.loadSeed(path);
      expect(seed, isNotNull, reason: '图里有一块明显的品红，应该挑得出来');
      final HSLColor picked = HSLColor.fromColor(seed!);
      final HSLColor pink = HSLColor.fromColor(const Color(0xFFE91E63));
      expect(
        (picked.hue - pink.hue).abs(),
        lessThan(30),
        reason: '主题色应该跟着那块品红，而不是深藏青',
      );
    });

    test('灰阶封面没有可用的种子色，但背景色照常有', () async {
      final String path = await makeCover(
        'gray',
        const Color(0xFF6E6E6E),
        const Color(0xFFBDBDBD),
      );
      expect(await CoverPaletteCache.load(path), isNotNull);
      expect(await CoverPaletteCache.loadSeed(path), isNull);
    });

    test('先取背景色再取种子色，只解码一次', () async {
      final String path = await makeCover(
        'cache',
        const Color(0xFF0D47A1),
        const Color(0xFFFFC107),
      );
      final List<Color>? first = await CoverPaletteCache.load(path);
      final Color? seed = await CoverPaletteCache.loadSeed(path);
      final List<Color>? second = await CoverPaletteCache.load(path);
      expect(seed, isNotNull);
      expect(identical(first, second), isTrue, reason: '应命中缓存');
    });

    test('没有封面时种子色也返回 null', () async {
      expect(await CoverPaletteCache.loadSeed(null), isNull);
      expect(await CoverPaletteCache.loadSeed(''), isNull);
      expect(await CoverPaletteCache.loadSeed('/missing/cover.jpg'), isNull);
    });
  });
}
