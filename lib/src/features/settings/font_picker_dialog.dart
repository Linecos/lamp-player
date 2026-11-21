import 'dart:async';

import 'package:flutter/material.dart';

import '../../common/text/bundled_fonts.dart';
import '../../common/text/lyric_font.dart';
import '../../common/text/system_fonts.dart';
import 'widgets/settings_rows.dart';

/// 打开「选择字体」弹窗，返回选中的字体族名；`null` = 用户取消。
///
/// [defaultLabel] 是空串那一项的说明（界面字体是「默认（微软雅黑 Light）」，
/// 歌词字体是「跟随界面字体」），因为两处默认值的含义不同。
///
/// [families] 只为测试注入固定列表；正常走 [systemFontFamilies]。
Future<String?> showFontPickerDialog(
  BuildContext context, {
  required String current,
  required String defaultLabel,
  List<String>? families,
}) {
  return showDialog<String>(
    context: context,
    builder: (BuildContext context) => _FontPickerDialog(
      current: current,
      defaultLabel: defaultLabel,
      families: families,
    ),
  );
}

/// 一行「标题 + 右侧可点的字体胶囊」，点开 [showFontPickerDialog]。
///
/// 不再用下拉：本机字体动辄上百款，下拉框一屏放不下也搜不了；弹窗里能搜索，
/// 每一项还用它自己的字形画出来，选之前就能看出差别。
class FontSettingRow extends StatelessWidget implements SettingsSearchable {
  const FontSettingRow({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.defaultLabel,
    required this.pillKey,
    required this.onChanged,
    this.searchExtra = '',
    this.families,
  });

  final IconData icon;
  final String title;
  final String? subtitle;

  /// 配置里存的值：空串表示默认项
  final String value;
  final String defaultLabel;

  /// 胶囊的 key：测试与快捷键定位用
  final Key pillKey;
  final ValueChanged<String>? onChanged;

  /// 额外参与设置页搜索的词（「界面字体」这类标题之外的同义词）
  final String searchExtra;

  /// 测试注入的字体列表，正常为 null
  final List<String>? families;

  @override
  String get searchText => '$title ${subtitle ?? ''} $searchExtra';

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final String display = value.isEmpty ? defaultLabel : lyricFontLabel(value);

    return Padding(
      // 与 _SwitchRow / _ChoiceRow 同一套版式：40 圆形底 + 16 间距
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Row(
        children: <Widget>[
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHigh,
              shape: BoxShape.circle,
            ),
            child: Icon(icon, size: 20, color: scheme.onSurfaceVariant),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(title, style: theme.textTheme.bodyLarge),
                if (subtitle != null) ...<Widget>[
                  const SizedBox(height: 2),
                  Text(
                    subtitle!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 12),
          // 字体名可能很长（"Source Han Sans SC Medium"）：限宽 + 截断，
          // 不让它把这一行撑破
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 240),
            child: Material(
              type: MaterialType.transparency,
              child: InkWell(
                key: pillKey,
                borderRadius: BorderRadius.circular(999),
                onTap: onChanged == null
                    ? null
                    : () => unawaited(_pick(context)),
                child: Container(
                  padding: const EdgeInsets.fromLTRB(12, 7, 14, 7),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(color: scheme.outlineVariant),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      // 参考常见字体选择器：前缀用「Aa」而不是箱形图标
                      Text(
                        'Aa',
                        style: theme.textTheme.labelLarge?.copyWith(
                          color: scheme.onSurfaceVariant,
                          height: 1,
                          letterSpacing: 0.5,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          display,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          // 胶囊里用选了的那款字体画，和弹窗列表里同一套观感
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontFamily: lyricFontFamilyOrNull(value),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _pick(BuildContext context) async {
    final String? picked = await showFontPickerDialog(
      context,
      current: value,
      defaultLabel: defaultLabel,
      families: families,
    );
    if (picked != null) {
      onChanged?.call(picked);
    }
  }
}

/// 弹窗里的一行：字体族名本身（空串是默认项），值是写进配置的族名
class _FontChoice {
  const _FontChoice(this.value, this.label, this.family);

  final String value;
  final String label;

  /// 渲染这一行用的字体；默认项为 null（跟着主题走）
  final String? family;
}

class _FontPickerDialog extends StatefulWidget {
  const _FontPickerDialog({
    required this.current,
    required this.defaultLabel,
    this.families,
  });

  final String current;
  final String defaultLabel;
  final List<String>? families;

  @override
  State<_FontPickerDialog> createState() => _FontPickerDialogState();
}

class _FontPickerDialogState extends State<_FontPickerDialog> {
  final TextEditingController _search = TextEditingController();

  /// 本机字体列表；null = 还在读
  List<String>? _families;
  String _query = '';

  @override
  void initState() {
    super.initState();
    final List<String>? injected = widget.families;
    if (injected != null) {
      _families = injected;
    } else {
      unawaited(_load());
    }
  }

  Future<void> _load() async {
    final List<String> families = await systemFontFamilies();
    if (!mounted) {
      return;
    }
    setState(() => _families = families);
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  /// 默认项 → 随包 MiSans → 本机字体（读不到时退回内置中文字体表）
  List<_FontChoice> _choices() {
    final List<String> system = _families ?? const <String>[];
    final List<String> fallback = system.isEmpty
        ? <String>[
            for (final (String family, String _) in kLyricFontChoices.skip(1))
              family,
          ]
        : system;
    return <_FontChoice>[
      _FontChoice('', widget.defaultLabel, null),
      for (final BundledFontFace face in kMiSansFaces)
        if (registeredBundledFamilies.contains(face.family))
          _FontChoice(face.family, face.label, face.family),
      for (final String family in fallback)
        if (!isBundledMiSansFamily(family))
          _FontChoice(family, _labelFor(family), family),
    ];
  }

  /// 内置表里的中文名拼在族名前面：`宋体（SimSun）`，搜哪个都能命中
  String _labelFor(String family) {
    final String alias = lyricFontLabel(family);
    return alias == family ? family : '$alias（$family）';
  }

  bool _hit(_FontChoice choice) {
    final String query = _query.toLowerCase();
    return choice.label.toLowerCase().contains(query) ||
        choice.value.toLowerCase().contains(query) ||
        lyricFontLabel(choice.value).toLowerCase().contains(query);
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final bool loading = _families == null;
    final String normalized = normalizeLyricFontFamily(widget.current);
    final List<_FontChoice> shown = loading
        ? const <_FontChoice>[]
        : _choices().where(_hit).toList(growable: false);

    final Size viewport = MediaQuery.sizeOf(context);
    // 窗口最矮 560：固定 480 的列表会把标题和搜索框挤出屏幕，按视口收一收
    final double listHeight = (viewport.height - 220).clamp(200.0, 480.0);
    final double listWidth = (viewport.width - 160).clamp(280.0, 440.0);

    return AlertDialog(
      key: const ValueKey<String>('font-picker-dialog'),
      clipBehavior: Clip.antiAlias,
      titlePadding: const EdgeInsets.fromLTRB(24, 16, 12, 8),
      contentPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      title: Row(
        children: <Widget>[
          Icon(Icons.text_fields, size: 22, color: scheme.primary),
          const SizedBox(width: 10),
          const Expanded(child: Text('选择字体')),
          IconButton(
            tooltip: '关闭',
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.close, size: 20),
          ),
        ],
      ),
      content: SizedBox(
        width: listWidth,
        // 字体多的时候（一两百款）别把弹窗撑出屏幕
        height: listHeight,
        child: Column(
          children: <Widget>[
            TextField(
              key: const ValueKey<String>('font-picker-search'),
              controller: _search,
              autofocus: true,
              onChanged: (String value) =>
                  setState(() => _query = value.trim()),
              decoration: InputDecoration(
                isDense: true,
                hintText: '搜索字体名，如 宋体 / YaHei',
                prefixIcon: const Icon(Icons.search, size: 20),
                suffixIcon: _query.isEmpty
                    ? null
                    : IconButton(
                        tooltip: '清除',
                        onPressed: () {
                          _search.clear();
                          setState(() => _query = '');
                        },
                        icon: const Icon(Icons.close, size: 18),
                      ),
                filled: true,
                fillColor: scheme.surfaceContainerHighest,
                // 弹窗底与搜索框同色系，光填充分不出边界，补一圈描边
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: scheme.outlineVariant),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: loading
                  ? const Center(
                      child: SizedBox.square(
                        dimension: 22,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  : shown.isEmpty
                  ? Center(
                      child: Text(
                        '未找到匹配字体',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    )
                  : Material(
                      type: MaterialType.transparency,
                      child: ListView.builder(
                        itemCount: shown.length,
                        itemExtent: 44,
                        addAutomaticKeepAlives: false,
                        addSemanticIndexes: false,
                        itemBuilder: (BuildContext context, int index) {
                          final _FontChoice choice = shown[index];
                          return _FontRow(
                            choice: choice,
                            current: normalized,
                            onTap: () =>
                                Navigator.of(context).pop(choice.value),
                          );
                        },
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FontRow extends StatelessWidget {
  const _FontRow({
    required this.choice,
    required this.current,
    required this.onTap,
  });

  final _FontChoice choice;
  final String current;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final bool active = choice.value == current;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: active ? scheme.primary.withValues(alpha: 0.12) : null,
          borderRadius: BorderRadius.circular(12),
        ),
        // 高亮底由 DecoratedBox 画，InkWell 的水波纹要落在它上层
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            key: ValueKey<String>('font-choice-${choice.value}'),
            borderRadius: BorderRadius.circular(12),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      choice.label,
                      maxLines: 1,
                      softWrap: false,
                      overflow: TextOverflow.fade,
                      // 每项用它自己的字形画：选之前就能看出差别
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontFamily: choice.family,
                        color: active ? scheme.primary : null,
                        fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                      ),
                    ),
                  ),
                  if (active)
                    Icon(Icons.check, size: 18, color: scheme.primary),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
