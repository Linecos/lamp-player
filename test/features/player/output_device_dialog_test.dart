import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_player/src/features/player/output_device_dialog.dart';
import 'package:lamp_player/src/rust/api/player.dart' as rust;
import 'package:lamp_player/src/theme/app_theme.dart';

const List<rust.PlayerDevice> _devices = <rust.PlayerDevice>[
  rust.PlayerDevice(index: 1, name: '扬声器', isDefault: true),
  rust.PlayerDevice(index: 2, name: '耳机', isDefault: false),
];

/// 打开弹窗，把返回值写进 [onPicked]
Future<void> _open(
  WidgetTester tester,
  void Function(int? picked) onPicked, {
  int selected = -1,
  List<rust.PlayerDevice> devices = _devices,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(const Color(0xFF2196F3)),
      home: Builder(
        builder: (BuildContext context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () async => onPicked(
                await showOutputDeviceDialog(
                  context,
                  devices: devices,
                  selected: selected,
                ),
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

void main() {
  testWidgets('弹窗列出系统默认与所有设备，当前设备带勾', (WidgetTester tester) async {
    await _open(tester, (int? _) {}, selected: 2);

    expect(
      find.byKey(const ValueKey<String>('output-device-dialog')),
      findsOneWidget,
    );
    expect(find.text('系统默认'), findsOneWidget);
    expect(find.text('扬声器'), findsOneWidget);
    expect(find.text('耳机'), findsOneWidget);

    // 当前设备那一行才有勾，别的行没有
    expect(
      find.descendant(
        of: find.byKey(const ValueKey<String>('output-device-item-2')),
        matching: find.byIcon(Icons.check),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey<String>('output-device-item--1')),
        matching: find.byIcon(Icons.check),
      ),
      findsNothing,
    );
  });

  testWidgets('只有耳机那条换成耳机图标，其余与标题仍是音箱', (WidgetTester tester) async {
    await _open(tester, (int? _) {}, selected: 2);

    // 耳机那行（选中）用实心耳机
    expect(
      find.descendant(
        of: find.byKey(const ValueKey<String>('output-device-item-2')),
        matching: find.byIcon(Icons.headphones),
      ),
      findsOneWidget,
      reason: '名字里有「耳机」的那条用耳机字形',
    );
    // 扬声器那行、系统默认那行仍是音箱，选中与否只在实心 / 描边之间切
    expect(
      find.descendant(
        of: find.byKey(const ValueKey<String>('output-device-item-1')),
        matching: find.byIcon(Icons.speaker_outlined),
      ),
      findsOneWidget,
      reason: '扬声器不该被换成耳机',
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey<String>('output-device-item--1')),
        matching: find.byIcon(Icons.speaker_outlined),
      ),
      findsOneWidget,
      reason: '系统默认不是耳机',
    );
    // 标题图标照旧
    expect(find.byIcon(Icons.speaker_outlined), findsWidgets);
    // 只有一朵耳机图标（那条设备行），没有泛滥到每一行
    expect(find.byIcon(Icons.headphones), findsOneWidget);
    expect(find.byIcon(Icons.headphones_outlined), findsNothing);
  });

  testWidgets('英文名的耳机也能认出来（headphone / airpods）', (WidgetTester tester) async {
    final List<rust.PlayerDevice> mixed = <rust.PlayerDevice>[
      rust.PlayerDevice(index: 1, name: 'Realtek(R) Audio', isDefault: true),
      rust.PlayerDevice(
        index: 2,
        name: 'Headphones (USB Audio)',
        isDefault: false,
      ),
      rust.PlayerDevice(index: 3, name: 'AirPods Pro', isDefault: false),
    ];
    await _open(tester, (int? _) {}, selected: -1, devices: mixed);

    expect(
      find.descendant(
        of: find.byKey(const ValueKey<String>('output-device-item-2')),
        matching: find.byIcon(Icons.headphones_outlined),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey<String>('output-device-item-3')),
        matching: find.byIcon(Icons.headphones_outlined),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey<String>('output-device-item-1')),
        matching: find.byIcon(Icons.speaker_outlined),
      ),
      findsOneWidget,
      reason: '声卡仍用音箱',
    );
  });

  testWidgets('点一行就返回该设备下标', (WidgetTester tester) async {
    int? picked;
    await _open(tester, (int? value) => picked = value);

    await tester.tap(find.text('耳机'));
    await tester.pumpAndSettle();

    expect(picked, 2);
    expect(
      find.byKey(const ValueKey<String>('output-device-dialog')),
      findsNothing,
    );
  });

  testWidgets('选系统默认返回 -1', (WidgetTester tester) async {
    int? picked;
    await _open(tester, (int? value) => picked = value, selected: 2);

    await tester.tap(find.text('系统默认'));
    await tester.pumpAndSettle();

    expect(picked, -1);
  });

  testWidgets('直接关掉返回 null，不当成选了第一项', (WidgetTester tester) async {
    int? picked = -99;
    await _open(tester, (int? value) => picked = value);

    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();

    expect(picked, isNull);
  });

  testWidgets('存档里的设备已经不在了就不高亮任何一行', (WidgetTester tester) async {
    await _open(tester, (int? _) {}, selected: 99);

    expect(
      find.descendant(
        of: find.byKey(const ValueKey<String>('output-device-dialog')),
        matching: find.byIcon(Icons.check),
      ),
      findsNothing,
    );
  });
}
