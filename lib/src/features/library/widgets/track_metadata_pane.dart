import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../../common/common.dart';
import '../../../rust/api/metadata.dart';
import '../../player/player_bar.dart';
import 'lyrics_editor_dialog.dart';

/// 「编辑音频信息」区块：占据曲库页右侧整块内容区（与历史 / 专辑分区同级），
/// 不是弹窗。左上角返回箭头回到进入前的分区。
///
/// 版式：标题区（返回 + 大标题 + 文件名）打头，中间一张卡片（左封面、右表单），
/// 底部是取消 / 保存。歌词收成表单里的一个入口，点开才是独立子窗
/// （[LyricsEditorDialog]）——歌词一屏几十行，铺在这里会把字段挤走。
///
/// 数据与副作用全部由调用方注入：`tags` / `lyricsText` 是进来时的快照，
/// `onSave` / `onShiftLyrics` / `onPickCover` 才真正选图与落盘，所以这个文件
/// 只负责「长得对、改得动」，单元测试不需要初始化 Rust。
class TrackMetadataPane extends StatefulWidget {
  const TrackMetadataPane({
    super.key,
    required this.filePath,
    required this.coverPath,
    required this.tags,
    required this.lyricsText,
    required this.lyricsSource,
    required this.onShiftLyrics,
    required this.onPickCover,
    required this.onSave,
    required this.onClose,
  });

  /// 音频文件绝对路径：标题下面显示文件名，完整路径放 tooltip
  final String filePath;

  /// 封面缓存文件路径（可空：没有封面时显示占位）
  final String? coverPath;

  /// 进来时的标签
  final TrackTags tags;

  /// 进来时的歌词原文（LRC / TTML 原样，可为空）
  final String lyricsText;

  /// 歌词来源：`sidecar`（同名 `.lrc` / `.ttml`）/ `embedded`（音频标签）/ `none`
  final String lyricsSource;

  /// 整体平移时间戳：透传给歌词子窗（负数提前、正数延后）
  final Future<String> Function(String text, int deltaMs) onShiftLyrics;

  /// 选一张本地图片当封面，返回它的路径；用户取消返回 null。
  ///
  /// 只负责「选」，不落盘：真正的写入在保存时一起做，用户点了取消就不会
  /// 平白改掉文件。
  final Future<String?> Function() onPickCover;

  /// 保存：由外面写标签 / 封面 / 歌词并同步曲库。
  /// 抛异常表示失败，界面保持打开并显示原因。
  final Future<void> Function(MetadataDraft draft) onSave;

  /// 返回（不保存）
  final VoidCallback onClose;

  @override
  State<TrackMetadataPane> createState() => TrackMetadataPaneState();
}

/// 保存时要落盘的全部内容：标签 + 歌词 + 新封面 + 歌词写入位置。
///
/// 用一个结构体而不是四个位置参数：这四样是「同一次编辑」的四部分，
/// 加字段时不用再改一遍调用方的签名。
class MetadataDraft {
  const MetadataDraft({
    required this.tags,
    required this.lyrics,
    required this.embedLyrics,
    this.coverSource,
  });

  final TrackTags tags;

  /// 歌词原文（LRC / TTML 原样）
  final String lyrics;

  /// `true` = 写进音频标签；`false` = 写同名 `.lrc`
  final bool embedLyrics;

  /// 新选的封面图片路径；null 表示没换
  final String? coverSource;
}

class TrackMetadataPaneState extends State<TrackMetadataPane> {
  /// 封面边长上限。再大就把表单挤成一条，再小看不清是什么图
  static const double _coverMaxSide = 200;

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
  late final TextEditingController _composer = _from(widget.tags.composer);
  late final TextEditingController _lyricist = _from(widget.tags.lyricist);
  late final TextEditingController _comment = _from(widget.tags.comment);

  /// 歌词在子窗里改，这里只留当前文本（子窗返回 null 表示用户取消了）
  late String _lyrics = widget.lyricsText;

  /// 歌词写到哪儿：原本内嵌的就默认内嵌，否则默认旁载 `.lrc`
  late bool _embedLyrics = widget.lyricsSource == 'embedded';

  /// 用户新选的封面（本地图片路径）。图片先显示出来，保存时才真正写进文件
  String? _pickedCover;

  bool _saving = false;

  /// 底部错误提示（保存失败、标题空）
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
    _composer,
    _lyricist,
    _comment,
  ];

  @override
  void dispose() {
    for (final TextEditingController controller in _fields) {
      controller.dispose();
    }
    super.dispose();
  }

  /// 点「编辑歌词…」：子窗返回新文本才覆盖，取消则原样留着
  Future<void> _editLyrics() async {
    final String? edited = await showDialog<String>(
      context: context,
      builder: (BuildContext dialogContext) => LyricsEditorDialog(
        lyricsText: _lyrics,
        lyricsSource: widget.lyricsSource,
        embedTarget: _embedLyrics,
        onShiftLyrics: widget.onShiftLyrics,
      ),
    );
    if (!mounted || edited == null) {
      return;
    }
    setState(() => _lyrics = edited);
  }

  Future<void> _pickCover() async {
    final String? picked = await widget.onPickCover();
    if (!mounted || picked == null) {
      return;
    }
    setState(() {
      _pickedCover = picked;
      _error = null;
    });
  }

  Future<void> _save() async {
    if (_saving) {
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
        MetadataDraft(
          tags: TrackTags(
            title: _title.text.trim(),
            artist: _artist.text.trim(),
            album: _album.text.trim(),
            albumArtist: _albumArtist.text.trim(),
            year: _year.text.trim(),
            trackNo: _trackNo.text.trim(),
            discNo: _discNo.text.trim(),
            genre: _genre.text.trim(),
            composer: _composer.text.trim(),
            lyricist: _lyricist.text.trim(),
            comment: _comment.text.trim(),
          ),
          lyrics: _lyrics,
          embedLyrics: _embedLyrics,
          coverSource: _pickedCover,
        ),
      );
      if (mounted) {
        widget.onClose();
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = '保存失败：$error';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _buildHeader(theme, scheme),
        Expanded(
          child: SingleChildScrollView(
            // 底部留出播放岛的高度：滚到底时「保存」停在岛上方，不被压住
            padding: EdgeInsets.only(bottom: PlayerBar.occupiedHeight + 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                _buildCard(theme, scheme),
                const SizedBox(height: 16),
                _buildFooter(theme, scheme),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// 顶部：返回箭头 + 大标题 + 文件名。
  ///
  /// 三样东西挤在一个 44 高的小行里会糊成一团：标题与文件名之间留 6px、
  /// 整块与下面的卡片之间留 16px，标题字号抬到 headlineSmall（与各分区的
  /// 标题同一档），返回箭头纵向居中于两行文字而不是贴着标题。
  Widget _buildHeader(ThemeData theme, ColorScheme scheme) {
    return Padding(
      padding: const EdgeInsets.only(top: 2, bottom: 16),
      child: Row(
        children: <Widget>[
          IconButton(
            onPressed: _saving ? null : widget.onClose,
            icon: const Icon(Icons.arrow_back),
            tooltip: '返回',
            visualDensity: VisualDensity.compact,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  '编辑音频信息',
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 6),
                Tooltip(
                  message: widget.filePath,
                  waitDuration: const Duration(milliseconds: 400),
                  child: Row(
                    children: <Widget>[
                      Icon(
                        Icons.insert_drive_file_outlined,
                        size: 14,
                        color: scheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          // 显式用 `p.windows`：路径风格是**数据**的属性，不是
                          // 跑测试那台机器的。`p.basename` 会按当前平台挑风格，
                          // CI 在 ubuntu 上跑时 Windows 路径切不开，界面会把整条
                          // 路径当地名显示（这条断言当年就是这么挂的）
                          p.windows.basename(widget.filePath),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 卡片：左封面、右表单
  Widget _buildCard(ThemeData theme, ColorScheme scheme) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        // 区块宽度随侧栏展开 / 窗口大小变；封面吃一部分但封顶，
        // 表单至少留出 320，够两列输入
        final double coverSide = math.max(
          96,
          math.min(_coverMaxSide, constraints.maxWidth * 0.26),
        );
        return Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            // 内容区底色是 surfaceContainerLow，卡片要更亮一层才有「一张板」的感觉
            color: scheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: scheme.outlineVariant),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              _buildCoverColumn(theme, scheme, coverSide),
              const SizedBox(width: 24),
              Expanded(
                child: LayoutBuilder(
                  builder: (BuildContext context, BoxConstraints form) {
                    return _buildForm(theme, scheme, form.maxWidth);
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// 左列：可点击的封面 + 一句说明
  Widget _buildCoverColumn(ThemeData theme, ColorScheme scheme, double side) {
    final String? picked = _pickedCover;
    return SizedBox(
      width: side,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _coverBox(scheme, side, picked),
          const SizedBox(height: 10),
          Text(
            picked == null ? '点击封面可以换一张' : '保存后生效',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: picked == null ? scheme.onSurfaceVariant : scheme.primary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _coverBox(ColorScheme scheme, double side, String? picked) {
    final Widget image = picked != null
        ? Image.file(
            File(picked),
            width: side,
            height: side,
            fit: BoxFit.cover,
            // 选完才发现读不了（文件被移走 / 不是图片）：退回占位，
            // 不要抛出一个红框
            errorBuilder: (BuildContext context, Object error, StackTrace? _) =>
                _coverPlaceholder(scheme, side),
          )
        : AlbumCover(path: widget.coverPath, size: side, radius: 12);
    return Semantics(
      button: true,
      label: '更换封面',
      child: Tooltip(
        message: '点击更换封面',
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Stack(
            children: <Widget>[
              image,
              Positioned.fill(
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    key: const ValueKey<String>('metadata-cover-pick'),
                    onTap: _pickCover,
                    hoverColor: scheme.primary.withValues(alpha: 0.08),
                  ),
                ),
              ),
              // 右下角一个小相机：光靠「悬停变亮」不够，得让人一眼看出能点
              Positioned(
                right: 6,
                bottom: 6,
                child: IgnorePointer(
                  child: Container(
                    padding: const EdgeInsets.all(5),
                    decoration: BoxDecoration(
                      color: scheme.surface.withValues(alpha: 0.86),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.photo_camera_outlined,
                      size: 15,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _coverPlaceholder(ColorScheme scheme, double side) {
    return Container(
      width: side,
      height: side,
      color: scheme.secondaryContainer,
      alignment: Alignment.center,
      child: Icon(
        Icons.music_note,
        size: side * 0.3,
        color: scheme.onSecondaryContainer,
      ),
    );
  }

  /// 右列表单。
  ///
  /// 宽的时候短字段三三并排（12 个字段排成一列要滚两屏），窄一点两两并排，
  /// 再窄退回单列——并排挤成 100px 的输入框比长一点更难用。
  Widget _buildForm(ThemeData theme, ColorScheme scheme, double width) {
    final int perRow = width >= 620 ? 3 : (width >= 420 ? 2 : 1);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _field(_title, '标题', Icons.music_note),
        ..._rows(<Widget>[
          _field(_artist, '艺术家', Icons.person_outline),
          _field(_album, '专辑', Icons.album_outlined),
          _field(_albumArtist, '专辑艺术家', Icons.groups_outlined),
          _field(
            _year,
            '年份',
            Icons.calendar_today_outlined,
            hint: perRow > 1 ? '2003' : '2003 或 2003-05-01',
          ),
          _field(_trackNo, '音轨号', Icons.numbers, hint: '3 或 03/12'),
          _field(_discNo, '碟号', Icons.album),
          _field(_genre, '流派', Icons.category_outlined),
          _field(_composer, '作曲家', Icons.piano_outlined),
          _field(_lyricist, '作词家', Icons.edit_note),
        ], perRow),
        _field(_comment, '注释', Icons.notes, lines: 2),
        const SizedBox(height: 4),
        _buildLyricsEntry(theme, scheme),
        const SizedBox(height: 6),
        Text(
          '留空表示清掉这个标签。',
          style: theme.textTheme.bodySmall?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  /// 把字段每 [perRow] 个摆一行，行内等宽均分、间距 12。
  ///
  /// 最后一行没排满时补空位，否则剩下的字段会被拉宽、和上面几行的列宽对不齐。
  List<Widget> _rows(List<Widget> fields, int perRow) {
    final List<Widget> rows = <Widget>[];
    for (int start = 0; start < fields.length; start += perRow) {
      final List<Widget> slice = fields.sublist(
        start,
        math.min(start + perRow, fields.length),
      );
      rows.add(
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            for (int i = 0; i < perRow; i += 1) ...<Widget>[
              if (i > 0) const SizedBox(width: 12),
              Expanded(
                child: i < slice.length ? slice[i] : const SizedBox.shrink(),
              ),
            ],
          ],
        ),
      );
    }
    return rows;
  }

  /// 单个字段：MD3 的 outlined 输入框（标签浮在描边上，聚焦时边框转主色）。
  ///
  /// 交给 Material 的浮动标签，缺口、圆角、聚焦加粗都是规范里的样子；
  /// 自己画「框外小字 + 填充框」那套一列下来像糊了一排贴片。
  Widget _field(
    TextEditingController controller,
    String label,
    IconData icon, {
    String? hint,
    int lines = 1,
  }) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: TextField(
        key: ValueKey<String>('metadata-field-$label'),
        controller: controller,
        style: theme.textTheme.bodyMedium,
        minLines: 1,
        maxLines: lines,
        // 注释可能有好几行：回车换行，别当单行提交
        keyboardType: lines > 1 ? TextInputType.multiline : null,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          isDense: true,
          alignLabelWithHint: lines > 1,
          prefixIcon: Icon(icon, size: 18, color: scheme.onSurfaceVariant),
          prefixIconConstraints: const BoxConstraints(
            minWidth: 40,
            minHeight: 44,
          ),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 12,
            vertical: 14,
          ),
          border: fieldBorder(scheme.outline),
          enabledBorder: fieldBorder(scheme.outline),
          focusedBorder: fieldBorder(scheme.primary, width: 2),
          floatingLabelBehavior: FloatingLabelBehavior.auto,
        ),
      ),
    );
  }

  /// 歌词入口：摘要 + 「写到哪儿」的开关，真正的改动在子窗里做
  Widget _buildLyricsEntry(ThemeData theme, ColorScheme scheme) {
    final int lines = _lyrics
        .split('\n')
        .where((String line) => line.trim().isNotEmpty)
        .length;
    final String sourceLabel = switch (widget.lyricsSource) {
      'sidecar' => '来自 .lrc',
      'embedded' => '来自文件内嵌',
      _ => '暂无歌词',
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.35),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: scheme.outlineVariant),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(
                  Icons.lyrics_outlined,
                  size: 18,
                  color: scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 8),
                Text('歌词', style: theme.textTheme.labelLarge),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    lines == 0
                        ? '$sourceLabel · 还没有内容'
                        : '$sourceLabel · $lines 行',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            // 分段按钮不做成「撑满整行」：两个选项各占半屏会显得像两条工具条，
            // 而且它本身只需要两百多像素。用 Wrap 让「编辑歌词…」贴右边，
            // 窄到放不下时自动换行，不会把按钮挤出台面。
            SizedBox(
              width: double.infinity,
              child: Wrap(
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 12,
                runSpacing: 8,
                children: <Widget>[
                  SegmentedButton<bool>(
                    key: const ValueKey<String>('metadata-lyrics-target'),
                    showSelectedIcon: false,
                    style: const ButtonStyle(
                      visualDensity: VisualDensity.compact,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    segments: const <ButtonSegment<bool>>[
                      ButtonSegment<bool>(
                        value: false,
                        label: Text('.lrc 文件'),
                        icon: Icon(Icons.description_outlined, size: 16),
                      ),
                      ButtonSegment<bool>(
                        value: true,
                        label: Text('音频标签'),
                        icon: Icon(Icons.audio_file_outlined, size: 16),
                      ),
                    ],
                    selected: <bool>{_embedLyrics},
                    onSelectionChanged: _saving
                        ? null
                        : (Set<bool> value) =>
                              setState(() => _embedLyrics = value.first),
                  ),
                  OutlinedButton.icon(
                    onPressed: _editLyrics,
                    icon: const Icon(Icons.edit_outlined, size: 18),
                    label: const Text('编辑歌词…'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFooter(ThemeData theme, ColorScheme scheme) {
    final String hint = _embedLyrics
        ? '保存会把标签、封面与歌词一起写进音频文件。'
        : '保存会写入音频标签与封面；歌词落到同名 .lrc。';
    return Row(
      children: <Widget>[
        Expanded(
          child: Text(
            _error ?? hint,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              color: _error == null ? scheme.onSurfaceVariant : scheme.error,
            ),
          ),
        ),
        const SizedBox(width: 12),
        TextButton(
          onPressed: _saving ? null : widget.onClose,
          child: const Text('取消'),
        ),
        const SizedBox(width: 8),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: Text(_saving ? '保存中…' : '保存'),
        ),
      ],
    );
  }
}
