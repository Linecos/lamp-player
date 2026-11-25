import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../theme/tokens.dart';

/// 一个标记块：标题 / 列表项 / 段落 / 代码块 / 分隔线。
enum MdBlockKind { heading, bullet, ordered, paragraph, code, rule }

/// [parseMarkdown] 的产物，保留成数据是为了能脱离 widget 单测解析结果。
@immutable
class MdBlock {
  const MdBlock(this.kind, {this.text = '', this.level = 1, this.index = 1});

  final MdBlockKind kind;

  /// 文本内容；[MdBlockKind.code] 时是多行原文，[MdBlockKind.rule] 时为空。
  final String text;

  /// 标题层级 1~6；[MdBlockKind.bullet] 时表示缩进层级（本项目暂只用 1）。
  final int level;

  /// 有序列表的序号，从 1 开始。
  final int index;

  @override
  String toString() =>
      'MdBlock(${kind.name}, level: $level, index: $index, text: $text)';
}

/// 把一段 Markdown 拆成块。
///
/// 只认这些写法（GitHub Release 正文里实际会出现的子集）：
/// `#`~`######` 标题、`-` / `*` / `+` 无序列表、`1.` 有序列表、
/// 三个反引号围起来的代码块、`---` 分隔线，其余按段落。
/// 表格、图片、引用、嵌套列表都当普通段落处理——刻意不追求完整实现，
/// 免得为了渲染一段发行说明去理解一整套语法。
List<MdBlock> parseMarkdown(String source) {
  final List<String> lines = source
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .split('\n');
  final List<MdBlock> blocks = <MdBlock>[];
  final List<String> paragraph = <String>[];
  final List<String> code = <String>[];
  bool inFence = false;

  void flushParagraph() {
    if (paragraph.isEmpty) {
      return;
    }
    blocks.add(MdBlock(MdBlockKind.paragraph, text: _joinSoftLines(paragraph)));
    paragraph.clear();
  }

  for (final String raw in lines) {
    final String line = raw.trimRight();
    final String trimmed = line.trimLeft();

    if (trimmed.startsWith('```')) {
      flushParagraph();
      if (inFence) {
        blocks.add(MdBlock(MdBlockKind.code, text: code.join('\n')));
        code.clear();
      }
      inFence = !inFence;
      continue;
    }
    if (inFence) {
      code.add(line);
      continue;
    }

    if (trimmed.isEmpty) {
      flushParagraph();
      continue;
    }

    final RegExpMatch? heading = RegExp(r'^(#{1,6})\s+(.*)$')
        .firstMatch(trimmed);
    if (heading != null) {
      flushParagraph();
      blocks.add(
        MdBlock(
          MdBlockKind.heading,
          level: heading.group(1)!.length,
          text: heading.group(2)!.trim(),
        ),
      );
      continue;
    }

    if (RegExp(r'^([-*_])\s*\1\s*\1[\s\-*_]*$').hasMatch(trimmed)) {
      flushParagraph();
      blocks.add(const MdBlock(MdBlockKind.rule));
      continue;
    }

    final RegExpMatch? ordered = RegExp(r'^(\d{1,3})[.)]\s+(.*)$')
        .firstMatch(trimmed);
    if (ordered != null) {
      flushParagraph();
      blocks.add(
        MdBlock(
          MdBlockKind.ordered,
          index: int.tryParse(ordered.group(1)!) ?? 1,
          text: ordered.group(2)!,
        ),
      );
      continue;
    }

    final RegExpMatch? bullet = RegExp(r'^[-*+]\s+(.*)$').firstMatch(trimmed);
    if (bullet != null) {
      flushParagraph();
      blocks.add(MdBlock(MdBlockKind.bullet, text: bullet.group(1)!));
      continue;
    }

    paragraph.add(trimmed);
  }

  // 代码块没闭合就当普通段落收尾，别把尾巴吞掉
  if (inFence && code.isNotEmpty) {
    blocks.add(MdBlock(MdBlockKind.code, text: code.join('\n')));
  }
  flushParagraph();
  return blocks;
}

/// 段落里的换行是软换行：中文之间直接接上，西文之间补一个空格。
String _joinSoftLines(List<String> lines) {
  final StringBuffer buffer = StringBuffer(lines.first);
  for (int i = 1; i < lines.length; i++) {
    final String prev = lines[i - 1];
    final String next = lines[i];
    if (prev.isNotEmpty &&
        next.isNotEmpty &&
        !_isCjk(prev.codeUnitAt(prev.length - 1))) {
      buffer.write(' ');
    }
    buffer.write(next);
  }
  return buffer.toString();
}

bool _isCjk(int codeUnit) =>
    (codeUnit >= 0x2E80 && codeUnit <= 0x9FFF) ||
    (codeUnit >= 0xF900 && codeUnit <= 0xFAFF) ||
    (codeUnit >= 0xFF00 && codeUnit <= 0xFFEF);

/// 行内片段的解析结果，单独暴露出来方便断言样式。
@immutable
class MdSpan {
  const MdSpan(this.text, {this.bold = false, this.code = false, this.link});

  final String text;
  final bool bold;
  final bool code;

  /// 非空表示这是 `[文字](链接)` 里的链接地址。
  final String? link;

  @override
  String toString() => 'MdSpan($text, bold: $bold, code: $code, link: $link)';
}

/// 把一行文本拆成粗体 / 行内代码 / 链接 / 普通文本四种片段。
List<MdSpan> parseInline(String text) {
  final List<MdSpan> spans = <MdSpan>[];
  final StringBuffer plain = StringBuffer();

  void flushPlain() {
    if (plain.isEmpty) {
      return;
    }
    spans.add(MdSpan(plain.toString()));
    plain.clear();
  }

  int i = 0;
  while (i < text.length) {
    // **粗体**
    if (text.startsWith('**', i)) {
      final int end = text.indexOf('**', i + 2);
      if (end > i + 2) {
        flushPlain();
        spans.add(MdSpan(text.substring(i + 2, end), bold: true));
        i = end + 2;
        continue;
      }
    }
    // `行内代码`
    if (text[i] == '`') {
      final int end = text.indexOf('`', i + 1);
      if (end > i + 1) {
        flushPlain();
        spans.add(MdSpan(text.substring(i + 1, end), code: true));
        i = end + 1;
        continue;
      }
    }
    // [文字](链接)
    if (text[i] == '[') {
      final int labelEnd = text.indexOf(']', i + 1);
      if (labelEnd > i + 1 &&
          labelEnd + 1 < text.length &&
          text[labelEnd + 1] == '(') {
        final int urlEnd = text.indexOf(')', labelEnd + 2);
        if (urlEnd > labelEnd + 2) {
          flushPlain();
          spans.add(
            MdSpan(
              text.substring(i + 1, labelEnd),
              link: text.substring(labelEnd + 2, urlEnd),
            ),
          );
          i = urlEnd + 1;
          continue;
        }
      }
    }
    plain.write(text[i]);
    i++;
  }
  flushPlain();
  return spans;
}

/// 极简 Markdown 渲染：标题 / 列表 / 段落 / 代码块 / 分隔线 + 粗体、行内代码、链接。
///
/// 用在发行说明这种「别人写的、我们只负责显示」的短文本上。
class MiniMarkdown extends StatefulWidget {
  const MiniMarkdown({
    super.key,
    required this.data,
    this.style,
    this.onOpenLink,
    this.blockSpacing = Spacing.xs,
  });

  final String data;

  /// 正文样式；标题在此基础上加粗、加大。
  final TextStyle? style;

  /// 点链接时回调；为 null 时链接只上色、不可点。
  final ValueChanged<String>? onOpenLink;

  /// 块与块之间的间距。
  final double blockSpacing;

  @override
  State<MiniMarkdown> createState() => _MiniMarkdownState();
}

class _MiniMarkdownState extends State<MiniMarkdown> {
  final List<TapGestureRecognizer> _recognizers = <TapGestureRecognizer>[];

  @override
  void dispose() {
    _disposeRecognizers();
    super.dispose();
  }

  void _disposeRecognizers() {
    for (final TapGestureRecognizer recognizer in _recognizers) {
      recognizer.dispose();
    }
    _recognizers.clear();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final TextStyle base =
        widget.style ?? theme.textTheme.bodySmall ?? const TextStyle();

    _disposeRecognizers();
    final List<MdBlock> blocks = parseMarkdown(widget.data);
    final List<Widget> children = <Widget>[];
    for (int i = 0; i < blocks.length; i++) {
      if (i > 0) {
        children.add(SizedBox(height: widget.blockSpacing));
      }
      children.add(_buildBlock(context, blocks[i], base, scheme));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: children,
    );
  }

  Widget _buildBlock(
    BuildContext context,
    MdBlock block,
    TextStyle base,
    ColorScheme scheme,
  ) {
    switch (block.kind) {
      case MdBlockKind.heading:
        final double size = (base.fontSize ?? 12) + (block.level <= 2 ? 2 : 1);
        return RichText(
          text: TextSpan(
            children: _spans(block.text, base, scheme),
            style: base.copyWith(
              fontSize: size,
              fontWeight: FontWeight.w600,
              color: scheme.onSurface,
            ),
          ),
        );
      case MdBlockKind.bullet:
        return _withMarker('•', block.text, base, scheme);
      case MdBlockKind.ordered:
        return _withMarker('${block.index}.', block.text, base, scheme);
      case MdBlockKind.code:
        return Container(
          width: double.infinity,
          padding: const EdgeInsets.all(Spacing.xs),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
            borderRadius: BorderRadius.circular(Radii.xs),
          ),
          child: Text(
            block.text,
            style: base.copyWith(
              fontFamily: 'Consolas',
              fontFamilyFallback: const <String>['Courier New', 'monospace'],
              height: 1.4,
            ),
          ),
        );
      case MdBlockKind.rule:
        return Divider(
          height: widget.blockSpacing * 2,
          thickness: 1,
          color: scheme.outlineVariant,
        );
      case MdBlockKind.paragraph:
        return RichText(
          text: TextSpan(
            children: _spans(block.text, base, scheme),
            style: base,
          ),
        );
    }
  }

  Widget _withMarker(
    String marker,
    String text,
    TextStyle base,
    ColorScheme scheme,
  ) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        SizedBox(
          width: 16,
          child: Text(
            marker,
            style: base.copyWith(color: scheme.onSurfaceVariant, height: 1.5),
          ),
        ),
        Expanded(
          child: RichText(
            text: TextSpan(children: _spans(text, base, scheme), style: base),
          ),
        ),
      ],
    );
  }

  List<InlineSpan> _spans(String text, TextStyle base, ColorScheme scheme) {
    return <InlineSpan>[
      for (final MdSpan span in parseInline(text))
        if (span.link != null)
          TextSpan(
            text: span.text,
            style: base.copyWith(
              color: scheme.primary,
              decoration: TextDecoration.underline,
              decorationColor: scheme.primary,
            ),
            recognizer: widget.onOpenLink == null
                ? null
                : _linkRecognizer(span.link!),
          )
        else if (span.code)
          TextSpan(
            text: span.text,
            style: base.copyWith(
              fontFamily: 'Consolas',
              fontFamilyFallback: const <String>['Courier New', 'monospace'],
              backgroundColor: scheme.surfaceContainerHighest,
            ),
          )
        else
          TextSpan(
            text: span.text,
            style: span.bold
                ? base.copyWith(
                    fontWeight: FontWeight.w600,
                    color: scheme.onSurface,
                  )
                : null,
          ),
    ];
  }

  TapGestureRecognizer _linkRecognizer(String url) {
    final TapGestureRecognizer recognizer = TapGestureRecognizer()
      ..onTap = () => widget.onOpenLink?.call(url);
    _recognizers.add(recognizer);
    return recognizer;
  }
}
