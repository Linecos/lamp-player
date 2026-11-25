import 'package:flutter/material.dart';

import '../../theme/tokens.dart';

/// 输入框的统一描边：MD3 outlined text field 的规格（圆角 4）。
///
/// 只画一条细边、不加填充：卡片本身已经有底色，再填一层会比卡片还亮，
/// 每个字段就成了一块贴片。
OutlineInputBorder fieldBorder(Color color, {double width = 1}) {
  return OutlineInputBorder(
    borderRadius: BorderRadius.circular(Radii.xs),
    borderSide: BorderSide(color: color, width: width),
  );
}
