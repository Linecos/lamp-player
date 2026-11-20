import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../../common/common.dart';
import '../../../rust/api/metadata.dart';
import '../../../rust/api/model.dart';
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
    required this.track,
    required this.coverPath,
    required this.tags,
    required this.lyricsText,
    required this.lyricsSource,
    required this.onShiftLyrics,
    required this.onPickCover,
    required this.onSave,
    required this.onClose,
    this.onProbeChannels,
  });

  /// 音频文件绝对路径：标题下面显示文件名，完整路径放 tooltip
  final String filePath;

  /// 曲库里的那一条：表单下面那几张信息卡片的数据源。
  ///
  /// 只读展示，编辑仍然只走 [tags]——这两份数据的来源不同（一个是扫描入库的
  /// 派生量，一个是文件标签），混在一个结构里反而容易互相覆盖。
  final Track track;

  /// 探测声道数：库里不存这一列，编辑页打开时按需读一次文件头。
  ///
  /// 为空（或探测失败）显示「—」，不让一条展示信息卡住编辑页。
  final Future<int?> Function()? onProbeChannels;

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

  /// 表单滚轮平滑（见 [SmoothScrollController]）
  final SmoothScrollController _scroll = SmoothScrollController();

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

  /// 文件的修改 / 变更时间：只有系统知道，Dart 侧直接 stat 一次
  DateTime? _modifiedAt;
  DateTime? _changedAt;

  /// 声道数（0 = 未知）
  int _channels = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_loadFacts());
  }

  /// 补两样曲库里没有的展示信息：声道数与文件时间戳。
  ///
  /// 两步各自落盘、各自失败得起：读不到就留空显示「—」。拆开是因为声道数
  /// 靠读文件头（毫秒级）、文件时间是系统调用，谁先回来就先显示谁。
  Future<void> _loadFacts() async {
    final Future<int?> Function()? probe = widget.onProbeChannels;
    if (probe != null) {
      try {
        final int channels = await probe() ?? 0;
        if (mounted) {
          setState(() => _channels = channels);
        }
      } on Object {
        // 解析失败：留空，不要挡住编辑页
      }
    }
    try {
      final FileStat stat = await File(widget.filePath).stat();
      if (mounted) {
        setState(() {
          _modifiedAt = stat.modified;
          _changedAt = stat.changed;
        });
      }
    } on Object {
      // 文件被移走 / 没有权限：留空
    }
  }

  @override
  void dispose() {
    for (final TextEditingController controller in _fields) {
      controller.dispose();
    }
    _scroll.dispose();
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
            controller: _scroll,
            // 底部留出播放岛的高度：滚到底时最后一张卡片停在岛上方，不被压住。
            // 保存 / 取消在标题行（不随内容滚动），所以这里不用再给按钮让位
            padding: EdgeInsets.only(bottom: PlayerBar.occupiedHeight + 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                _buildCard(theme, scheme),
                const SizedBox(height: 12),
                _buildInfoCards(theme, scheme),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// 顶部：返回箭头 + 大标题 + 文件名，右侧是**常驻**的取消 / 保存。
  ///
  /// 按钮不放底部：下面那三张信息卡是只读的，编辑上面的字段要保存时还得
  /// 滚过一屏不需要动的内容才能点到按钮，不划算。放在标题行后，无论滚到
  /// 哪儿都在原位。
  ///
  /// 三样标题信息挤在一个 44 高的小行里会糊成一团：标题与文件名之间留 6px、
  /// 整块与下面的卡片之间留 16px，标题字号抬到 headlineSmall（与各分区的
  /// 标题同一档），返回箭头纵向居中于两行文字而不是贴着标题。
  Widget _buildHeader(ThemeData theme, ColorScheme scheme) {
    return Padding(
      padding: const EdgeInsets.only(top: 2, bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              IconButton(
                onPressed: _saving ? null : widget.onClose,
                icon: const Icon(Icons.arrow_back),
                tooltip: '返回',
                visualDensity: VisualDensity.compact,
              ),
              const SizedBox(width: 6),
              Expanded(
                flex: 2,
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
                              // 显式用 `p.windows`：路径风格是**数据**的属性，
                              // 不是跑测试那台机器的。`p.basename` 会按当前平台
                              // 挑风格，CI 在 ubuntu 上跑时 Windows 路径切不开，
                              // 界面会把整条路径当地名显示（这条断言当年就是这
                              // 么挂的）
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
              // 保存失败 / 标题空这类提示紧挨着按钮：它跟按钮在同一个视线里，
              // 不用滚到底才发现没保存成功
              if (_error != null) ...<Widget>[
                const SizedBox(width: 12),
                Flexible(
                  child: Text(
                    _error!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.right,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.error,
                    ),
                  ),
                ),
              ],
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

  /// 表单下面那三张信息卡片：曲库里的派生量 + 文件系统的事实。
  ///
  /// 宽屏三列、中等两列、窄屏一列——挤成三列 100px 宽时读起来比堆一屏还费劲。
  /// 每张卡片自己带边框，跟上面那张「封面 + 表单」的板子同一档材质。
  Widget _buildInfoCards(ThemeData theme, ColorScheme scheme) {
    final Track track = widget.track;
    final List<(String, IconData, List<(String, String)>)> groups =
        <(String, IconData, List<(String, String)>)>[
          (
            '音频参数',
            Icons.graphic_eq,
            <(String, String)>[
              ('时长', formatTrackDuration(track.durationSecs)),
              ('比特率', formatBitrate(track.audioBitrate)),
              ('采样率', formatSampleRate(track.sampleRate)),
              ('位深', formatBitDepth(track.bitDepth)),
              ('通道数', formatChannels(_channels)),
            ],
          ),
          (
            '电平与增益',
            Icons.waves,
            <(String, String)>[
              ('音轨编号', formatTrackNumber(track.trackNum)),
              (
                '音轨峰值',
                formatPeak(
                  track.truePeak > 0 ? track.truePeak : track.samplePeak,
                ),
              ),
              ('音轨增益', formatGainDb(track.replayGain)),
              ('响度', formatLoudness(track.loudnessLufs)),
            ],
          ),
          (
            '存储信息',
            Icons.save_outlined,
            <(String, String)>[
              ('文件格式', formatFileFormat(track.path)),
              ('文件大小', formatFileSize(track.fileSize)),
              ('修改时间', formatMoment(_modifiedAt)),
              ('变更时间', formatMoment(_changedAt)),
              ('完整路径', track.path),
            ],
          ),
        ];
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final int columns = constraints.maxWidth >= 880
            ? 3
            : (constraints.maxWidth >= 620 ? 2 : 1);
        const double gap = 12;
        final double cardWidth =
            (constraints.maxWidth - gap * (columns - 1)) / columns;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: <Widget>[
            for (final (
                  String title,
                  IconData icon,
                  List<(String, String)> rows,
                )
                in groups)
              SizedBox(
                width: cardWidth,
                child: _infoCard(theme, scheme, title, icon, rows),
              ),
          ],
        );
      },
    );
  }

  Widget _infoCard(
    ThemeData theme,
    ColorScheme scheme,
    String title,
    IconData icon,
    List<(String, String)> rows,
  ) {
    return Container(
      key: ValueKey<String>('metadata-info-$title'),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(icon, size: 16, color: scheme.onSurfaceVariant),
              const SizedBox(width: 6),
              Text(
                title,
                style: theme.textTheme.labelLarge?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          for (int i = 0; i < rows.length; i += 1) ...<Widget>[
            if (i > 0)
              Divider(
                height: 1,
                color: scheme.outlineVariant.withValues(alpha: 0.5),
              ),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    rows[i].$1,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    rows[i].$2,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 时长：`04:10`，满一小时写成 `1:04:10`。未知（0 / 非有限值）显示 `—`。
String formatTrackDuration(double seconds) {
  if (!seconds.isFinite || seconds <= 0) {
    return '—';
  }
  final int total = seconds.round();
  final int hours = total ~/ 3600;
  final String minutes = ((total % 3600) ~/ 60).toString().padLeft(2, '0');
  final String secs = (total % 60).toString().padLeft(2, '0');
  return hours > 0 ? '$hours:$minutes:$secs' : '$minutes:$secs';
}

/// 平均码率：`1819 kbps`；未知（0）显示 `—`
String formatBitrate(int kbps) => kbps <= 0 ? '—' : '$kbps kbps';

/// 采样率：`48000 Hz`；未知（0）显示 `—`
String formatSampleRate(int hz) => hz <= 0 ? '—' : '$hz Hz';

/// 位深：`24 bit`；有损编码没有这个值，显示 `—`
String formatBitDepth(int bits) => bits <= 0 ? '—' : '$bits bit';

/// 声道数：`2 声道`；1 写成「单声道」更好读；未知（0）显示 `—`
String formatChannels(int channels) => switch (channels) {
  <= 0 => '—',
  1 => '单声道',
  _ => '$channels 声道',
};

/// 音轨号：库里没有就是 null，显示 `—`
String formatTrackNumber(int? number) =>
    number == null || number <= 0 ? '—' : '$number';

/// 峰值（线性幅度）：`0.98`；未知（0 / 非有限值）显示 `—`
String formatPeak(double peak) =>
    !peak.isFinite || peak <= 0 ? '—' : peak.toStringAsFixed(2);

/// ReplayGain 曲目增益：`-7.62 dB`。
///
/// 0 表示**标签里没有**（`Track.replayGain` 的口径），不是「增益正好 0 dB」，
/// 所以显示 `—`。
String formatGainDb(double db) =>
    !db.isFinite || db.abs() < 0.005 ? '—' : '${db.toStringAsFixed(2)} dB';

/// 积分响度：`-14.3 LUFS`；0 = 还没现场分析过，显示 `—`
String formatLoudness(double lufs) =>
    !lufs.isFinite || lufs == 0 ? '—' : '${lufs.toStringAsFixed(1)} LUFS';

/// 文件大小：`55.64 MB`；未知（0）显示 `—`
String formatFileSize(int bytes) {
  if (bytes <= 0) {
    return '—';
  }
  const int kb = 1024;
  const int mb = kb * 1024;
  const int gb = mb * 1024;
  if (bytes >= gb) {
    return '${(bytes / gb).toStringAsFixed(2)} GB';
  }
  if (bytes >= mb) {
    return '${(bytes / mb).toStringAsFixed(2)} MB';
  }
  return '${(bytes / kb).toStringAsFixed(1)} KB';
}

/// 文件格式取扩展名：`FLAC`。
///
/// 用 `p.windows` 显式按 Windows 风格切：路径风格是**数据**的属性，
/// 不是跑测试那台机器的（CI 在 ubuntu 上跑，按当前平台切会切不开）。
String formatFileFormat(String path) {
  final String ext = p.windows
      .extension(path)
      .replaceFirst('.', '')
      .toLowerCase();
  return ext.isEmpty ? '未知' : ext.toUpperCase();
}

/// 时间戳：`2026-08-13 15:05:24`；读不到就是 `—`
String formatMoment(DateTime? time) {
  if (time == null) {
    return '—';
  }
  String two(int value) => value.toString().padLeft(2, '0');
  return '${time.year}-${two(time.month)}-${two(time.day)} '
      '${two(time.hour)}:${two(time.minute)}:${two(time.second)}';
}
