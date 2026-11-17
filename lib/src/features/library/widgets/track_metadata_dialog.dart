import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show FilteringTextInputFormatter, TextInputFormatter;

import '../../../common/widgets/album_cover.dart';
import '../../../rust/api/metadata.dart';

/// 曲目「修改元数据」弹窗：左边改歌词，右边（右上角）看封面、改信息。
///
/// 数据与副作用全部由调用方注入——`tags` / `lyricsText` 是进来时的快照，
/// `onSave` / `onShiftLyrics` 才是真正落盘与平移时间戳的地方。这样这个文件
/// 只负责「长得对、改得动」，单元测试里不需要初始化 Rust。
///
/// 尺寸策略：980×660（跟随窗口缩，留 48 的边）。右侧信息列固定 380 宽、
/// 封面 168 见方贴**右上角**；左边歌词编辑器吃掉剩下的全部空间，因为歌词
/// 是一屏几十行、比八个单行输入框更需要地方。
class TrackMetadataDialog extends StatefulWidget {
  const TrackMetadataDialog({
    super.key,
    required this.coverPath,
    required this.tags,
    required this.lyricsText,
    required this.lyricsSource,
    required this.onShiftLyrics,
    required this.onSave,
  });

  /// 封面缓存文件路径（可空：没有封面时显示占位）
  final String? coverPath;

  /// 进来时的标签
  final TrackTags tags;

  /// 进来时的歌词原文（LRC / TTML 原样，可为空）
  final String lyricsText;

  /// 歌词来源：`sidecar`（同名 `.lrc` / `.ttml`）/ `embedded`（音频标签）/ `none`
  final String lyricsSource;

  /// 整体平移时间戳：返回平移后的新文本（负数提前、正数延后）
  final Future<String> Function(String text, int deltaMs) onShiftLyrics;

  /// 保存：标签 + 歌词原文。抛异常表示失败，弹窗保持打开并显示原因。
  final Future<void> Function(TrackTags tags, String lyrics) onSave;

  @override
  State<TrackMetadataDialog> createState() => _TrackMetadataDialogState();
}

class _TrackMetadataDialogState extends State<TrackMetadataDialog> {
  /// 信息列固定宽度：窗口再宽也不拉长输入框
  static const double _infoWidth = 380;

  /// 封面边长：够看清是哪张图，又不至于把字段挤到屏幕外
  static const double _coverSide = 168;

  late final TextEditingController _title = _from(widget.tags.title);
  late final TextEditingController _artist = _from(widget.tags.artist);
  late final TextEditingController _album = _from(widget.tags.album);
  late final TextEditingController _albumArtist = _from(
    widget.tags.albumArtist,
  );
  late final TextEditingController _year = _from(widget.tags.year);
  late final TextEditingController _trackNo = _from(widget.tags.trackNo);
  late final TextEditingController _discNo = _from(widget.tags.discNo);
  late final TextEditingController _genre = _from(widget.tags.genre);
  late final TextEditingController _lyrics = _from(widget.lyricsText);

  /// 偏移输入的「秒」「毫秒」两格，分开填更符合「快进 1 秒 200 毫秒」的说法
  final TextEditingController _offsetSeconds = TextEditingController();
  final TextEditingController _offsetMillis = TextEditingController();

  /// 提前还是延后：提前 = 时间戳减小（歌词更早出现）
  bool _delay = true;

  bool _saving = false;
  bool _shifting = false;

  /// 弹窗底部的错误提示（保存失败、平移失败、标题空）
  String? _error;

  TextEditingController _from(String value) =>
      TextEditingController(text: value);

  List<TextEditingController> get _fields => <TextEditingController>[
    _title,
    _artist,
    _album,
    _albumArtist,
    _year,
    _trackNo,
    _discNo,
    _genre,
  ];

  @override
  void dispose() {
    for (final TextEditingController controller in _fields) {
      controller.dispose();
    }
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
    if (_shifting || _saving) {
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
          // 没有时间戳可动（纯文本歌词 / 已经是 0 秒）：说清楚，别让人以为点坏了
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

  Future<void> _save() async {
    if (_saving || _shifting) {
      return;
    }
    if (_title.text.trim().isEmpty) {
      setState(() => _error = '标题不能为空（否则列表里会退回文件名）');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.onSave(
        TrackTags(
          title: _title.text.trim(),
          artist: _artist.text.trim(),
          album: _album.text.trim(),
          albumArtist: _albumArtist.text.trim(),
          year: _year.text.trim(),
          trackNo: _trackNo.text.trim(),
          discNo: _discNo.text.trim(),
          genre: _genre.text.trim(),
        ),
        _lyrics.text,
      );
      if (mounted) {
        Navigator.of(context).pop(true);
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = '保存失败：$error';
        });
      }
      return;
    }
    if (mounted) {
      setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final Size viewport = MediaQuery.sizeOf(context);

    final double width = math.min(980, math.max(560, viewport.width - 48));
    final double height = math.min(660, math.max(420, viewport.height - 48));
    final double infoWidth = math.min(_infoWidth, width * 0.44);

    return Dialog(
      clipBehavior: Clip.antiAlias,
      insetPadding: const EdgeInsets.all(24),
      child: SizedBox(
        width: width,
        height: height,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  // 左：歌词编辑器（占剩下的全部宽度）
                  Expanded(child: _buildLyricsPane(theme, scheme)),
                  // 右：封面在右上角，下面是信息字段
                  SizedBox(
                    width: infoWidth,
                    child: _buildInfoPane(theme, scheme),
                  ),
                ],
              ),
            ),
            _buildFooter(theme, scheme),
          ],
        ),
      ),
    );
  }

  Widget _buildLyricsPane(ThemeData theme, ColorScheme scheme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Text('歌词', style: theme.textTheme.titleSmall),
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
          const SizedBox(height: 8),
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
    );
  }

  /// 歌词来源小标签：告诉用户保存会落到哪个文件
  Widget _sourceChip(ThemeData theme, ColorScheme scheme) {
    final (String label, String tip) = switch (widget.lyricsSource) {
      'sidecar' => ('来自 .lrc', '保存时写回同名 .lrc'),
      'embedded' => ('来自文件内嵌', '保存时会新建同名 .lrc（不改音频文件）'),
      _ => ('暂无歌词', '保存时新建同名 .lrc'),
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
          onPressed: _shifting || _saving ? null : _applyOffset,
          icon: const Icon(Icons.fast_rewind, size: 18),
          label: Text(_shifting ? '平移中…' : '应用到时间轴'),
        ),
        const Spacer(),
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

  Widget _buildInfoPane(ThemeData theme, ColorScheme scheme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 20, 24, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          // 封面贴右上角
          Align(
            alignment: Alignment.topRight,
            child: AlbumCover(
              path: widget.coverPath,
              size: _coverSide,
              radius: 14,
            ),
          ),
          const SizedBox(height: 16),
          Expanded(
            child: SingleChildScrollView(
              // 长字段单列，短字段两两并排：8 个字段一列排下来会比信息列高，
              // 底部那个「流派」会被裁掉半截；并排之后 660 高的窗里正好放下
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  _textField(_title, '标题'),
                  _textField(_artist, '艺术家'),
                  _textField(_album, '专辑'),
                  _textField(_albumArtist, '专辑艺术家'),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Expanded(
                        flex: 3,
                        child: _textField(
                          _year,
                          '年份',
                          hint: '2003 或 2003-05-01',
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        flex: 2,
                        child: _textField(_trackNo, '音轨号', hint: '3 或 03/12'),
                      ),
                    ],
                  ),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Expanded(flex: 2, child: _textField(_discNo, '碟号')),
                      const SizedBox(width: 10),
                      Expanded(flex: 3, child: _textField(_genre, '流派')),
                    ],
                  ),
                  Text(
                    '留空表示清掉这个标签。',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _textField(
    TextEditingController controller,
    String label, {
    String? hint,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: TextField(
        controller: controller,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          isDense: true,
          border: const OutlineInputBorder(),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 12,
            vertical: 12,
          ),
        ),
      ),
    );
  }

  Widget _buildFooter(ThemeData theme, ColorScheme scheme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              _error ?? '保存会写入音频文件的标签；歌词写入同名 .lrc（不改音频文件）。',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: _error == null ? scheme.onSurfaceVariant : scheme.error,
              ),
            ),
          ),
          const SizedBox(width: 12),
          TextButton(
            onPressed: _saving ? null : () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          const SizedBox(width: 8),
          FilledButton(
            onPressed: _saving || _shifting ? null : _save,
            child: Text(_saving ? '保存中…' : '保存'),
          ),
        ],
      ),
    );
  }
}
