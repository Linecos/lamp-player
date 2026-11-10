# 性能压测：万级曲库

> 测试日期：2026-10-24
> 基线：main `f85ea11`
> 构建：Windows release（`flutter build windows --release`）

## 测试环境

| 项 | 值 |
|---|---|
| 系统 | Windows 11 家庭版中文版 10.0.26200 |
| CPU | Intel Core i7-13700H（14 核 20 线程） |
| 内存 | 15.7 GB |
| Flutter | 本地 3.47.7（CI 固定 3.47.0） |
| 桥接 | flutter_rust_bridge 2.13 |
| 窗口 | 1280 × 800 |

## 测试数据

- **10,000 首 FLAC**，总大小 81 MB
- 每首 0.25 秒、44.1 kHz、单声道，仅用于压测，不含真实音乐
- 500 张专辑（每张 20 首）、137 位艺术家、曲目号 1–20
- 每首内嵌同一张 8×8 PNG（用于触发封面提取；内容哈希去重后只落 1 个文件）
- 生成脚本使用 Python `soundfile` + `mutagen`，仅本地执行，不随仓库提交

## 方法

测量入口是临时探针，直接调用 Rust API，不经过界面：

- **冷扫描**：空库对 10k 目录执行一次 `scanFolder`
- **热扫描**：紧接着再执行一次，验证增量跳过
- `allTracks`：一次全量读取 10,000 条
- `searchTracks`：4 个查询（精确曲名、艺术家、专辑、数字前缀），limit 500
- 数据库体积：关闭连接后统计 `library.db` + `-wal` + `-shm`
- **列表滚动**：release 应用加载 10k 曲库，向曲库列表发送 180 次滚轮事件，
  用 `SchedulerBinding.addTimingsCallback` 统计每帧 `build + raster` 耗时

## 结果

### 扫描与查询

| 场景 | 耗时 | 结果 |
|---|---:|---|
| 冷扫描（10,000 首，含封面提取） | **10,063 ms** | upserted 10,000 / failed 0 |
| 热扫描（增量） | **229 ms** | unchanged 10,000 / upserted 0 |
| `allTracks` | **20 ms** | 10,000 条 |
| 搜索「曲目 09999」 | **1 ms** | 1 条 |
| 搜索「艺术家 007」 | **2 ms** | 372 条 |
| 搜索「专辑 0020」 | **0 ms** | 30 条 |
| 搜索「0999」 | **0 ms** | 10 条 |
| 数据库体积（含 WAL） | **3.18 MB** | 10,000 条元数据 |
| 封面缓存 | **1 个文件 / 74 B** | 内容哈希去重 |

### 列表滚动（release）

| 指标 | 值 |
|---|---:|
| 采样帧数 | 197 |
| 平均帧耗时 | **4.46 ms** |
| P50 | 4.17 ms |
| P95 | **7.00 ms** |
| 最大 | 12.51 ms |
| 超过 16.7 ms 的帧 | **0** |
| 超过 33.3 ms 的帧 | **0** |

## 解读

- 冷扫描约 **1.0 ms/首**，主要开销在文件 IO、FLAC 解码和封面提取；10k 首次导入约 10 秒
- 热扫描 **0.23 秒**，增量指纹生效，没有重复解析
- `allTracks` 20 ms、搜索 0–2 ms，曲库规模到 1 万条时查询侧没有压力
- 列表用 `ListView.builder` + `itemExtent` 虚拟滚动，滚动帧耗时 P95 7 ms，
  没有掉帧，满足 60 FPS
- 数据库 10k 条约 3 MB，体积正常

## 注意事项

- 压测文件只有 0.25 秒且共用一张 8×8 封面，因此冷扫描偏乐观、封面缓存极小；
  真实曲库的封面各不相同，缓存体积会明显增加，但去重逻辑已由 Rust 测试覆盖
- 以上为 release 数据；debug 构建下冷扫描约 11.5 秒、`allTracks` 约 95 ms，
  不作为验收口径
- 10k 曲库放在仓库外的 `D:\lamp-perf-library`，不进入版本库

## 帧耗时类测量的前提（2026-11-01 踩到过）

用 `FrameTiming`（`tool/hero_flight_bench.dart` 之类）量渲染开销时，**窗口必须在前台**：
窗口被遮挡或最小化时 Windows 不合成，`rasterDuration` 会给出 0.3 ms 这种「好看但没有
意义」的数字，据此下结论会南辕北辙。基准脚本自己的启动段要抢前台：

```dart
await windowManager.waitUntilReadyToShow(options, () async {
  await windowManager.show();
  await windowManager.focus();
  await windowManager.setAlwaysOnTop(true);
});
```

`flutter run` 拉起的窗口不一定会被系统切到前台，`--release` 下尤其容易被忽略。

配套结论：**封面 Hero 飞行带阴影与不带阴影的 raster 在同一量级**（均 0.3 ms、P95 0.4，
240 Hz 屏）。这份基准是裸页面（只有两个大方块，没有歌词 / 频谱 / 流光背景），绝对值不能
拿去和整页数字比，只用于比较两组之间的差额：阴影在 shuttle 里按固定尺寸光栅化一次、
之后每帧只改 `Transform` 矩阵，所以「boxShadow 每帧重做高斯模糊」的代价只在
「每帧按新尺寸重画」时才存在，固定尺寸缩放几乎不花钱。

## 歌词的逐行模糊：Impeller 下等于每帧重算（2026-11-11）

正在播放页挂着放歌，RSS 从 214MB 一路涨到 409MB（约 1MB/s）。用探针按
`PROBE_MODE=full|lyrics|blank` 逐层拆：

| 场景 | RSS | 说明 |
| --- | --- | --- |
| `blank`（24 秒） | 85 → 85MB | 排除引擎 / 框架自身 |
| `lyrics`，去掉模糊（24 秒） | 113 → 114MB | 只剩透明度渐变，平稳 |
| `lyrics`，原样（24 秒） | 145 → 163MB | 持续上涨 |
| `lyrics`，冻结进度（24 秒） | 107 → 157MB | 只在首次布局时涨，之后走平 |
| `full`，原样（5 分钟） | 169 → 228MB（峰值 247） | 持续上涨 |
| `full`，去掉模糊（5 分钟） | 152 → 169MB | 60 秒后走平 |

结论：**每行一个 `ImageFiltered(ui.ImageFilter.blur)` 就是增长源**。Impeller 没有
光栅缓存，`RepaintBoundary` 也挡不住——只要窗口里有任何动画在跑（当前行
`AnimatedScale`、换行回弹、逐字染色），图层树每帧都要重新合成，这几十个模糊图层的
离屏纹理就跟着反复分配。11-10 的 `4065ebe` 把当前行放大改成 600ms 的 `AnimatedScale`，
等于每换一句就多出 0.6 秒的持续重绘，把成本放大了：关掉缩放后增速从 +18MB/15s 降到
+5MB/15s，但没有归零。

试过但不可行的替代：

- `TextStyle.foreground` + `MaskFilter.blur`：Impeller 直接忽略，文字还是清晰的（截图确认）
- 透明字 + 模糊 `Shadow`：观感接近，但一样要分配纹理，RSS 仍以 +25MB/15s 上涨

最终方案：远处行只按距离压暗，不再模糊。

## 探针本身的两个坑

- `PROBE_MODE=lyrics` 的 24 秒窗口只够看斜率；判断「会不会收敛」得跑 5 分钟以上。
  这个模式不加载 Rust 引擎，**引擎侧的分配它量不到**，要对照真实进程的 `[mem]` 日志
- 探针窗口必须 `focus()` + `setAlwaysOnTop(true)`，否则 Windows 会裁工作集，数字偏低
