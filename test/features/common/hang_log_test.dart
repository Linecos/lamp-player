import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_player/src/common/hang_log.dart';

void main() {
  test('未启动时打点不落盘', () {
    // 守卫：widget / 单元测试里任何地方顺手调 hangMark 都不该往用户临时目录写文件，
    // 也不该留下定时器（那会让 flutter_test 报 pending timer）
    expect(hangLogStarted, isFalse);
    final file = File(hangLogPath);
    final existed = file.existsSync();
    final before = existed ? file.lengthSync() : -1;
    hangMark('测试');
    expect(hangLogStarted, isFalse);
    // 用户机器上常有真跑留下的日志（本机抓过卡死现场），只断言这次没有写进去
    if (existed) {
      expect(file.lengthSync(), before);
    } else {
      expect(file.existsSync(), isFalse);
    }
  });

  test('日志落在系统临时目录', () {
    expect(hangLogPath, startsWith(Directory.systemTemp.path));
    expect(hangLogPath, endsWith('lamp-player-hang.log'));
  });
}
