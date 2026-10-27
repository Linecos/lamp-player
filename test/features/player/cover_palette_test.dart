import 'dart:convert';
import 'dart:io';

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
}
