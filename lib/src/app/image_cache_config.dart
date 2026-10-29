import 'package:flutter/painting.dart';

/// 解码后封面图的内存缓存上限。
///
/// Flutter 默认是 100MB / 1000 张：曲库滚动一遍、再逛两圈专辑网格，缓存很容易
/// 吃满 100MB 却再也用不到（同一张封面在列表、专辑卡、正在播放页各有不同尺寸，
/// 每种尺寸都是一份独立的解码结果）。
///
/// 40MB 大约还能留住 150 张 2x 专辑卡（约 260KB/张）或 1500 张列表小封面
/// （约 25KB/张），远多于一个窗口能同时看到的数量；被淘汰的封面重新解码时
/// 原图还在系统文件缓存里，滚动回看几乎无感。
const int coverCacheMaxBytes = 40 << 20;

/// 缓存条目上限：与 [coverCacheMaxBytes] 一起限制「很多小图」的情况。
const int coverCacheMaxEntries = 240;

/// 收紧 Flutter 的图片缓存；启动时调用一次即可。
void configureImageCache() {
  final ImageCache cache = PaintingBinding.instance.imageCache;
  cache.maximumSize = coverCacheMaxEntries;
  cache.maximumSizeBytes = coverCacheMaxBytes;
}
