import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_player/src/common/text/mini_markdown.dart';

Widget _wrap(Widget child) {
  return MaterialApp(
    home: Scaffold(body: SingleChildScrollView(child: child)),
  );
}

/// 在渲染树里找某个文字片段对应的 TextSpan（用来断言它的样式）
TextSpan? _spanOf(WidgetTester tester, String text) {
  for (final RichText rich in tester.widgetList<RichText>(
    find.byType(RichText),
  )) {
    TextSpan? hit;
    rich.text.visitChildren((InlineSpan span) {
      if (span is TextSpan && span.text == text) {
        hit = span;
        return false;
      }
      return true;
    });
    if (hit != null) {
      return hit;
    }
  }
  return null;
}

void main() {
  test('解析标题、列表、代码块与分隔线', () {
    final List<MdBlock> blocks = parseMarkdown('''
### 新增

- **桌面歌词双行**：说明
- 第二条

1. 第一步
2. 第二步

```
code line
```

---
''');

    expect(blocks[0].kind, MdBlockKind.heading);
    expect(blocks[0].level, 3);
    expect(blocks[0].text, '新增');

    expect(blocks[1].kind, MdBlockKind.bullet);
    expect(blocks[1].text, '**桌面歌词双行**：说明');
    expect(blocks[2].kind, MdBlockKind.bullet);

    expect(blocks[3].kind, MdBlockKind.ordered);
    expect(blocks[3].index, 1);
    expect(blocks[4].kind, MdBlockKind.ordered);
    expect(blocks[4].index, 2);

    expect(blocks[5].kind, MdBlockKind.code);
    expect(blocks[5].text, 'code line');

    expect(blocks[6].kind, MdBlockKind.rule);
  });

  test('段落软换行：中文直接相接，西文补空格', () {
    final List<MdBlock> blocks = parseMarkdown('第一行中文\n第二行中文\n\nabc\ndef');
    expect(blocks[0].text, '第一行中文第二行中文');
    expect(blocks[1].text, 'abc def');
  });

  test('行内片段识别粗体、行内代码与链接', () {
    final List<MdSpan> spans = parseInline(
      '**桌面歌词**：`A-` / [下载](https://example.com/x.zip) 结束',
    );

    expect(spans.map((MdSpan s) => s.text).toList(), <String>[
      '桌面歌词',
      '：',
      'A-',
      ' / ',
      '下载',
      ' 结束',
    ]);
    expect(spans[0].bold, isTrue);
    expect(spans[2].code, isTrue);
    expect(spans[4].link, 'https://example.com/x.zip');
  });

  test('未闭合的记号按原文显示，不吞字', () {
    expect(parseInline('**没闭合的粗体').single.text, '**没闭合的粗体');
    expect(parseInline('[没有链接](半截').single.text, '[没有链接](半截');
    expect(parseMarkdown('```\n没闭上的代码块').single.kind, MdBlockKind.code);
  });

  testWidgets('渲染后页面里不再出现 Markdown 记号', (WidgetTester tester) async {
    await tester.pumpWidget(
      _wrap(
        const MiniMarkdown(
          data: '### 新增\n\n- **桌面歌词双行**：主行下方多一行\n\n### 修复\n\n- 某处',
        ),
      ),
    );

    expect(find.textContaining('###', findRichText: true), findsNothing);
    expect(find.textContaining('**', findRichText: true), findsNothing);
    expect(find.textContaining('桌面歌词双行', findRichText: true), findsOneWidget);
    expect(find.textContaining('•', findRichText: true), findsNWidgets(2));
    expect(
      find.text('新增', findRichText: true),
      findsOneWidget,
      reason: '标题去掉井号后按原文显示',
    );
  });

  testWidgets('粗体是 w600，行内代码用等宽字体', (WidgetTester tester) async {
    await tester.pumpWidget(
      _wrap(const MiniMarkdown(data: '- **双行**：窗口高度跟着变，`A-` 恢复默认')),
    );

    final TextSpan? bold = _spanOf(tester, '双行');
    expect(bold?.style?.fontWeight, FontWeight.w600);

    final TextSpan? code = _spanOf(tester, 'A-');
    expect(code?.style?.fontFamily, 'Consolas');
  });

  testWidgets('点链接会把地址交给回调', (WidgetTester tester) async {
    final List<String> opened = <String>[];
    await tester.pumpWidget(
      _wrap(
        MiniMarkdown(
          data: '下载：[安装包](https://example.com/setup.exe)',
          onOpenLink: opened.add,
        ),
      ),
    );

    final TextSpan? link = _spanOf(tester, '安装包');
    expect(link?.recognizer, isNotNull);
    (link!.recognizer as TapGestureRecognizer).onTap!();
    await tester.pump();

    expect(opened, <String>['https://example.com/setup.exe']);
  });

  testWidgets('没有回调时链接只上色、不可点', (WidgetTester tester) async {
    await tester.pumpWidget(
      _wrap(const MiniMarkdown(data: '看 [这里](https://example.com)')),
    );

    final TextSpan? link = _spanOf(tester, '这里');
    expect(link?.recognizer, isNull);
  });
}
