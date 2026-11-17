import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show FilteringTextInputFormatter, TextInputFormatter;

/// 歌词编辑子窗：改文本 + 整体平移时间戳。
///
/// 从「编辑音频信息」界面里点「编辑歌词…」进来。单独一个窗，是因为歌词
/// 天生占地方（一屏几十行），和八个单行输入框抢同一层次只会谁都看不清。
///
/// 关闭时用 `Navigator.pop<String>` 把**新文本**带回父窗；「取消」返回 null，
/// 父窗据此决定要不要覆盖自己手里的那份。
class LyricsEditorDialog extends StatefulWidget {
  const LyricsEditorDialog({
    super.key,
    required this.lyricsText,
    required this.lyricsSource,
    required this.embedTarget,
    required this.onShiftLyrics,
  });

  /// 进来时的歌词原文（LRC / TTML 原样，可为空）
  final String lyricsText;

  /// 来源：`sidecar`（同名 `.lrc` / `.ttml`）/ `embedded`（音频标签）/ `none`
  final String lyricsSource;

  /// 上一层选的写入位置：true = 音频标签，false = 同名 `.lrc`。
  ///
  /// 子窗只负责改文本，落盘在上一层做；这里读它只是为了把「保存到哪儿」
  /// 说清楚，免得改完才发现写错了地方。
  final bool embedTarget;

  /// 整体平移时间戳：返回平移后的新文本（负数提前、正数延后）
  final Future<String> Function(String text, int deltaMs) onShiftLyrics;

  @override
  State<LyricsEditorDialog> createState() => _LyricsEditorDialogState();
}

class _LyricsEditorDialogState extends State<LyricsEditorDialog> {
  late final TextEditingController _lyrics = TextEditingController(
    text: widget.lyricsText,
  );

  /// 偏移输入的「秒」「毫秒」两格，分开填更符合「快进 1 秒 200 毫秒」的说法
  final TextEditingController _offsetSeconds = TextEditingController();
  final TextEditingController _offsetMillis = TextEditingController();

  /// 提前还是延后：提前 = 时间戳减小（歌词更早出现）
  bool _delay = true;

  bool _shifting = false;
  String? _error;

  @override
  void dispose() {
    _lyrics.dispose();
    _offsetSeconds.dispose();
    _offsetMillis.dispose();
    super.dispose();
  }

  /// 把「秒 + 毫秒 + 提前/延后」换算成毫秒增量；没填合法数字时返回 null
  int? _deltaMs() {
    final int seconds = int.tryParse(_offsetSeconds.text.trim()) ?? 0;
    final int millis = int.tryParse(_offsetMillis.text.trim()) ?? 0;
    if (seconds == 0 && millis == 0) {
      return null;
    }
    final int total = seconds * 1000 + millis;
    return _delay ? -total : total;
  }

  Future<void> _applyOffset() async {
    if (_shifting) {
      return;
    }
    final int? delta = _deltaMs();
    if (delta == null) {
      setState(() => _error = '先填要快进 / 延后多少秒或多少毫秒');
      return;
    }
    setState(() {
      _shifting = true;
      _error = null;
    });
    try {
      final String before = _lyrics.text;
      final String after = await widget.onShiftLyrics(before, delta);
      if (!mounted) {
        return;
      }
      setState(() {
        if (after == before) {
          // 没有时间戳可动（纯文本歌词 / 已经夹到 0）：说清楚，别让人以为点坏了
          _error = '这段歌词里没有可平移的时间戳，或平移后没有变化';
        } else {
          _lyrics.text = after;
          _lyrics.selection = TextSelection.collapsed(offset: after.length);
          _offsetSeconds.clear();
          _offsetMillis.clear();
        }
      });
    } catch (error) {
      if (mounted) {
        setState(() => _error = '平移时间戳失败：$error');
      }
    } finally {
      if (mounted) {
        setState(() => _shifting = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final Size viewport = MediaQuery.sizeOf(context);

    final double width = math.min(820, math.max(460, viewport.width - 96));
    final double height = math.min(620, math.max(360, viewport.height - 96));

    return Dialog(
      clipBehavior: Clip.antiAlias,
      insetPadding: const EdgeInsets.all(48),
      child: SizedBox(
        width: width,
        height: height,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        Text('编辑歌词', style: theme.textTheme.titleMedium),
                        const SizedBox(width: 8),
                        _sourceChip(theme, scheme),
                        const Spacer(),
                        Text(
                          '支持 LRC 时间戳，可直接编辑文本',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Expanded(
                      child: TextField(
                        key: const ValueKey<String>('lyrics-editor'),
                        controller: _lyrics,
                        expands: true,
                        maxLines: null,
                        minLines: null,
                        textAlignVertical: TextAlignVertical.top,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          // 等宽字体：时间戳与文本对得齐，改偏移时一眼看出哪行变了
                          fontFamily: 'Consolas',
                          height: 1.5,
                        ),
                        decoration: const InputDecoration(
                          hintText: '还没有歌词。可以直接粘贴 LRC 文本…',
                          border: OutlineInputBorder(),
                          contentPadding: EdgeInsets.all(12),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    _buildOffsetRow(theme, scheme),
                  ],
                ),
              ),
            ),
            _buildFooter(theme, scheme),
          ],
        ),
      ),
    );
  }

  /// 歌词来源小标签：告诉用户保存会落到哪个文件
  Widget _sourceChip(ThemeData theme, ColorScheme scheme) {
    final String targetLabel = widget.embedTarget ? '音频标签' : '同名 .lrc';
    final (String label, String tip) = switch (widget.lyricsSource) {
      'sidecar' => ('来自 .lrc', '保存时写入$targetLabel'),
      'embedded' => ('来自文件内嵌', '保存时写入$targetLabel'),
      _ => ('暂无歌词', '保存时写入$targetLabel'),
    };
    return Tooltip(
      message: tip,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(
          label,
          style: theme.textTheme.labelSmall?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }

  /// 整体平移一行：秒 / 毫秒 + 提前、延后 + 应用
  Widget _buildOffsetRow(ThemeData theme, ColorScheme scheme) {
    return Row(
      children: <Widget>[
        Text('整体偏移', style: theme.textTheme.labelLarge),
        const SizedBox(width: 10),
        SizedBox(width: 64, child: _numberField(_offsetSeconds, '秒')),
        const SizedBox(width: 8),
        SizedBox(width: 84, child: _numberField(_offsetMillis, '毫秒')),
        const SizedBox(width: 12),
        SegmentedButton<bool>(
          showSelectedIcon: false,
          style: const ButtonStyle(
            visualDensity: VisualDensity.compact,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          segments: const <ButtonSegment<bool>>[
            ButtonSegment<bool>(value: true, label: Text('提前')),
            ButtonSegment<bool>(value: false, label: Text('延后')),
          ],
          selected: <bool>{_delay},
          onSelectionChanged: (Set<bool> value) =>
              setState(() => _delay = value.first),
        ),
        const SizedBox(width: 12),
        OutlinedButton.icon(
          onPressed: _shifting ? null : _applyOffset,
          icon: const Icon(Icons.fast_rewind, size: 18),
          label: Text(_shifting ? '平移中…' : '应用到时间轴'),
        ),
      ],
    );
  }

  Widget _numberField(TextEditingController controller, String label) {
    return TextField(
      controller: controller,
      keyboardType: TextInputType.number,
      inputFormatters: <TextInputFormatter>[
        FilteringTextInputFormatter.digitsOnly,
      ],
      decoration: InputDecoration(
        labelText: label,
        isDense: true,
        border: const OutlineInputBorder(),
        contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
      ),
      style: Theme.of(context).textTheme.bodyMedium,
    );
  }

  Widget _buildFooter(ThemeData theme, ColorScheme scheme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 16),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              _error ?? '只改时间戳，不动歌词文本；回到上一层点「保存」才会写入文件。',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: _error == null ? scheme.onSurfaceVariant : scheme.error,
              ),
            ),
          ),
          const SizedBox(width: 12),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          const SizedBox(width: 8),
          FilledButton(
            onPressed: _shifting
                ? null
                : () => Navigator.of(context).pop(_lyrics.text),
            child: const Text('完成'),
          ),
        ],
      ),
    );
  }
}
