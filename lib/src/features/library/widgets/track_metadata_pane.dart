import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../../common/widgets/album_cover.dart';
import '../../../rust/api/metadata.dart';
import '../../player/player_bar.dart';
import 'lyrics_editor_dialog.dart';

/// 「编辑音频信息」区块：占据曲库页右侧整块内容区（与历史 / 专辑分区同级），
/// 不是弹窗。左上角返回箭头回到进入前的分区。
///
/// 版式：大标题 + 文件名打头，中间一张卡片（左封面、右表单），底部是
/// 取消 / 保存。歌词收成表单里的一个入口，点开才是独立子窗
/// （[LyricsEditorDialog]）——歌词一屏几十行，铺在这里会把字段挤走。
///
/// 数据与副作用全部由调用方注入：`tags` / `lyricsText` 是进来时的快照，
/// `onSave` / `onShiftLyrics` 才真正落盘与平移时间戳，所以这个文件只负责
/// 「长得对、改得动」，单元测试不需要初始化 Rust。
class TrackMetadataPane extends StatefulWidget {
  const TrackMetadataPane({
    super.key,
    required this.filePath,
    required this.coverPath,
    required this.tags,
    required this.lyricsText,
    required this.lyricsSource,
    required this.onShiftLyrics,
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

  /// 保存：标签 + 歌词原文。抛异常表示失败，界面保持打开并显示原因。
  final Future<void> Function(TrackTags tags, String lyrics) onSave;

  /// 返回（不保存）
  final VoidCallback onClose;

  @override
  State<TrackMetadataPane> createState() => TrackMetadataPaneState();
}

class TrackMetadataPaneState extends State<TrackMetadataPane> {
  /// 封面边长上限。区块比弹窗宽得多，300 已经够显眼，再大就把表单挤成一条
  static const double _coverMaxSide = 300;

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

  /// 歌词在子窗里改，这里只留当前文本（子窗返回 null 表示用户取消了）
  late String _lyrics = widget.lyricsText;

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
        onShiftLyrics: widget.onShiftLyrics,
      ),
    );
    if (!mounted || edited == null) {
      return;
    }
    setState(() => _lyrics = edited);
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
        _lyrics,
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
            padding: EdgeInsets.only(
              bottom: PlayerBar.occupiedHeight + 8,
              top: 4,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                _buildCard(theme, scheme),
                const SizedBox(height: 14),
                _buildFooter(theme, scheme),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// 顶部：返回箭头 + 大标题 + 文件名（完整路径放 tooltip，长路径不占版面）
  Widget _buildHeader(ThemeData theme, ColorScheme scheme) {
    return Row(
      children: <Widget>[
        IconButton(
          onPressed: _saving ? null : widget.onClose,
          icon: const Icon(Icons.arrow_back),
          tooltip: '返回',
          visualDensity: VisualDensity.compact,
        ),
        const SizedBox(width: 4),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                '编辑音频信息',
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 2),
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
                        p.basename(widget.filePath),
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
    );
  }

  /// 卡片：左封面、右表单
  Widget _buildCard(ThemeData theme, ColorScheme scheme) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        // 区块宽度随侧栏展开 / 窗口大小变，封面跟着收，但不超过上限
        final double coverSide = math.max(
          96,
          math.min(_coverMaxSide, constraints.maxWidth * 0.28),
        );
        return Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            // 内容区底色是 surfaceContainerLow，卡片要更亮一层才有「一张板」的感觉
            color: scheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: scheme.outlineVariant),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              AlbumCover(path: widget.coverPath, size: coverSide, radius: 16),
              const SizedBox(width: 24),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    _field(_title, '标题', Icons.music_note),
                    _field(_artist, '艺术家', Icons.person_outline),
                    _field(_album, '专辑', Icons.album_outlined),
                    _field(_albumArtist, '专辑艺术家', Icons.groups_outlined),
                    // 短字段两两并排：一列排到底会把「流派」推到很下面
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Expanded(
                          flex: 3,
                          child: _field(
                            _year,
                            '年份',
                            Icons.calendar_today_outlined,
                            hint: '2003 或 2003-05-01',
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          flex: 2,
                          child: _field(
                            _trackNo,
                            '音轨号',
                            Icons.numbers,
                            hint: '3 或 03/12',
                          ),
                        ),
                      ],
                    ),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Expanded(
                          flex: 2,
                          child: _field(_discNo, '碟号', Icons.album),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          flex: 3,
                          child: _field(_genre, '流派', Icons.category_outlined),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    _buildLyricsEntry(theme, scheme),
                    const SizedBox(height: 10),
                    Text(
                      '留空表示清掉这个标签。',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// 单个字段：标签在框外（参考图那样），图标在框内左侧
  Widget _field(
    TextEditingController controller,
    String label,
    IconData icon, {
    String? hint,
  }) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.only(left: 2, bottom: 6),
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
          TextField(
            key: ValueKey<String>('metadata-field-$label'),
            controller: controller,
            style: theme.textTheme.bodyMedium,
            decoration: InputDecoration(
              hintText: hint,
              isDense: true,
              filled: true,
              fillColor: scheme.surfaceContainerHighest,
              prefixIcon: Icon(icon, size: 18, color: scheme.onSurfaceVariant),
              prefixIconConstraints: const BoxConstraints(
                minWidth: 40,
                minHeight: 40,
              ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 12,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide(color: scheme.outlineVariant),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide(color: scheme.outlineVariant),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 歌词入口：只显示来源与行数，真正的改动在子窗里做
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.only(left: 2, bottom: 6),
          child: Text(
            '歌词',
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ),
        Row(
          children: <Widget>[
            Icon(
              Icons.lyrics_outlined,
              size: 18,
              color: scheme.onSurfaceVariant,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                lines == 0 ? '$sourceLabel · 还没有内容' : '$sourceLabel · $lines 行',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              onPressed: _editLyrics,
              icon: const Icon(Icons.edit_outlined, size: 18),
              label: const Text('编辑歌词…'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildFooter(ThemeData theme, ColorScheme scheme) {
    return Row(
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
