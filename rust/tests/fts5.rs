//! 验证 bundled SQLite 编译时启用了 FTS5。
//!
//! 这是一个独立测试文件（不经过 api/ 模块），CI 的 cargo test 会执行它。
//! 说明：FTS5 默认 unicode61 分词器对 CJK 不分词，整段汉字串是一个 token，
//! 因此检索中文必须用前缀匹配（'xxx*'）——与 db.rs 的实现策略一致。

use rusqlite::Connection;

#[test]
fn bundled_sqlite_enables_fts5() {
    let conn = Connection::open_in_memory().expect("打开内存库");

    conn.execute_batch(
        r#"
        CREATE VIRTUAL TABLE t USING fts5(content);
        INSERT INTO t(content) VALUES ('本地音乐播放器');
        INSERT INTO t(content) VALUES ('hello world');
        "#,
    )
    .expect("建 FTS5 虚表失败 => bundled 未启用 FTS5");

    // 前缀匹配：中文
    let hits: i64 = conn
        .query_row("SELECT count(*) FROM t WHERE t MATCH '本地*'", [], |r| {
            r.get(0)
        })
        .expect("FTS5 MATCH 失败");
    assert_eq!(hits, 1, "中文前缀匹配应命中 1 条");

    // 分词匹配：拉丁
    let hits: i64 = conn
        .query_row("SELECT count(*) FROM t WHERE t MATCH 'world'", [], |r| {
            r.get(0)
        })
        .expect("FTS5 MATCH 失败");
    assert_eq!(hits, 1, "拉丁分词匹配应命中 1 条");
}
