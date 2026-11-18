//! 临时压测探针（不提交）：10k 曲库下的扫描 / 查询 / 聚合耗时。
//!
//! 跑法：`cargo run --release --example perf_probe -- <曲库目录> <临时库路径>`

use std::path::Path;
use std::time::Instant;

use rust_lib_lamp_player::api::{collections, db, scan};

fn ms(started: Instant) -> String {
    format!("{:.1}", started.elapsed().as_secs_f64() * 1000.0)
}

fn main() -> anyhow::Result<()> {
    let args: Vec<String> = std::env::args().collect();
    let folder = args
        .get(1)
        .cloned()
        .unwrap_or_else(|| r"D:\lamp-perf-library".to_string());
    let db_path = args.get(2).cloned().unwrap_or_else(|| {
        std::env::temp_dir()
            .join("lamp_perf.db")
            .display()
            .to_string()
    });
    let _ = std::fs::remove_file(&db_path);

    let t = Instant::now();
    db::init_db(db_path.clone())?;
    println!("init_db            {} ms", ms(t));

    // 冷扫描
    let t = Instant::now();
    let report = scan::scan_folder(folder.clone())?;
    println!(
        "cold_scan          {} ms  scanned={} upserted={} failed={} pruned={} walk_errors={}",
        ms(t),
        report.scanned,
        report.upserted,
        report.failed,
        report.pruned,
        report.walk_errors
    );
    println!("  report.elapsed_ms={}", report.elapsed_ms);

    // 热扫描（增量）
    let t = Instant::now();
    let report = scan::scan_folder(folder.clone())?;
    println!(
        "warm_scan          {} ms  unchanged={} upserted={}",
        ms(t),
        report.unchanged,
        report.upserted
    );

    // v10 启动补扫：指纹与大小清零后重扫（老库升级后的真实路径）
    {
        let conn = rusqlite::Connection::open(Path::new(&db_path))?;
        conn.execute(
            "UPDATE tracks SET file_mtime = 0, file_size = 0, audio_bitrate = 0, sample_rate = 0, bit_depth = 0",
            [],
        )?;
    }
    let t = Instant::now();
    let report = scan::scan_folder(folder.clone())?;
    println!(
        "backfill_scan      {} ms  unchanged={} upserted={}",
        ms(t),
        report.unchanged,
        report.upserted
    );

    // 全量读取
    for _ in 0..3 {
        let t = Instant::now();
        let tracks = db::all_tracks()?;
        println!("all_tracks         {} ms  rows={}", ms(t), tracks.len());
    }

    // 搜索
    for q in ["曲目 09999", "艺术家 007", "专辑 0020", "0999"] {
        let t = Instant::now();
        let hits = db::search_tracks(q.to_string(), 500)?;
        println!("search {:<12} {} ms  hits={}", q, ms(t), hits.len());
    }

    // 隐藏曲目 / 缺失清理（补扫后各页会用到）
    let t = Instant::now();
    let hidden = db::hidden_tracks()?;
    println!("hidden_tracks      {} ms  rows={}", ms(t), hidden.len());

    let all = db::all_tracks()?;
    let paths: Vec<String> = all.iter().map(|t| t.path.clone()).collect();

    // 收藏：写入 5000 条再读
    let half: Vec<String> = paths.iter().take(5000).cloned().collect();
    let t = Instant::now();
    let added = collections::set_favorites(half.clone(), true)?;
    println!("set_favorites      {} ms  added={}", ms(t), added);
    let t = Instant::now();
    let favs = collections::list_favorites()?;
    println!("list_favorites     {} ms  rows={}", ms(t), favs.len());
    let t = Instant::now();
    let fp = collections::favorite_paths()?;
    println!("favorite_paths     {} ms  rows={}", ms(t), fp.len());

    // 历史：记 3000 次播放再读最近 500
    for path in paths.iter().take(3000) {
        collections::record_play(path.clone())?;
    }
    let t = Instant::now();
    let recent = collections::recent_tracks(500)?;
    println!("recent_tracks      {} ms  rows={}", ms(t), recent.len());
    let t = Instant::now();
    let stats = collections::play_stats()?;
    println!(
        "play_stats         {} ms  tracks={} total={}s",
        ms(t),
        stats.track_count,
        stats.total_seconds
    );
    let t = Instant::now();
    let top = collections::top_tracks(500)?;
    println!("top_tracks         {} ms  rows={}", ms(t), top.len());

    // 歌单：10000 首全塞进一个歌单再整表读
    let pl = collections::create_playlist("压测歌单".to_string())?;
    let t = Instant::now();
    let added = collections::add_tracks_to_playlist(pl.id, paths.clone())?;
    println!("playlist_add_all   {} ms  added={}", ms(t), added);
    let t = Instant::now();
    let items = collections::playlist_tracks(pl.id)?;
    println!("playlist_tracks    {} ms  rows={}", ms(t), items.len());

    // 库体积
    db::close_db()?;
    let mut total: u64 = 0;
    for suffix in ["", "-wal", "-shm"] {
        let p = format!("{db_path}{suffix}");
        if let Ok(meta) = std::fs::metadata(&p) {
            total += meta.len();
        }
    }
    println!(
        "db_size            {:.2} MB",
        total as f64 / 1024.0 / 1024.0
    );
    Ok(())
}
