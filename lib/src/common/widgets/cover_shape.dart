import 'package:flutter/foundation.dart';

/// 封面是否显示成圆形。
///
/// 设置页改这个开关，[AlbumCover] 内部订阅：曲库列表、播放条、正在播放页
/// 等所有用到封面的地方一起变，不必层层透传参数。
final ValueNotifier<bool> circularCovers = ValueNotifier<bool>(false);
