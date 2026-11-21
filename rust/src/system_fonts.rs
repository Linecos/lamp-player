use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::OnceLock;

/// 已扫描过的字体族（进程内只扫一遍：字体文件加起来几十 MB，每次开弹窗都扫太慢）
fn cache() -> &'static OnceLock<Vec<String>> {
    static CACHE: OnceLock<Vec<String>> = OnceLock::new();
    &CACHE
}

/// 本机已安装的字体族名。
///
/// 走字体文件的 name 表，而不是 GDI 的 `EnumFontFamiliesEx`：后者按字符集返回，
/// 同一族会跟着语言重复出现，还得再挑一个「Flutter 与 GDI+ 都认」的名字。字体
/// 文件里的 family 名正是两边解析用的那个，且用户字体目录（`%LOCALAPPDATA%\
/// Microsoft\Windows\Fonts`，双击安装的用户字体在这里）也能扫到。
pub fn installed_families() -> Vec<String> {
    cache().get_or_init(scan_families).clone()
}

fn scan_families() -> Vec<String> {
    // 小写名 → 原始名：同一个族可能被多个文件（粗体 / 细体 / .ttc）重复报出来，
    // 用小写去重，显示保留第一次见到的写法
    let mut names: BTreeMap<String, String> = BTreeMap::new();
    for dir in font_dirs() {
        collect_dir(&dir, &mut names);
    }
    names.into_values().collect()
}

fn font_dirs() -> Vec<PathBuf> {
    let mut dirs = Vec::with_capacity(2);
    if let Ok(windir) = std::env::var("WINDIR") {
        dirs.push(PathBuf::from(windir).join("Fonts"));
    }
    if let Ok(local) = std::env::var("LOCALAPPDATA") {
        dirs.push(
            PathBuf::from(local)
                .join("Microsoft")
                .join("Windows")
                .join("Fonts"),
        );
    }
    dirs
}

fn collect_dir(dir: &Path, names: &mut BTreeMap<String, String>) {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        let ext = path
            .extension()
            .and_then(|e| e.to_str())
            .unwrap_or("")
            .to_ascii_lowercase();
        if !matches!(ext.as_str(), "ttf" | "ttc" | "otf") {
            continue;
        }
        let Ok(data) = std::fs::read(&path) else {
            continue;
        };
        // .ttc 是字体集合，一个文件里装好几个族；逐个 face 解析，解析失败即到头
        for index in 0..32u32 {
            let Ok(face) = ttf_parser::Face::parse(&data, index) else {
                break;
            };
            if let Some(name) = family_name(&face) {
                let name = name.trim().to_string();
                if name.is_empty() || name.starts_with('@') {
                    continue;
                }
                names.entry(name.to_lowercase()).or_insert(name);
            }
        }
    }
}

/// 取族名：用**传统族名**（name_id 1）。
///
/// Windows 把 Light / Semibold 这类字重也当成独立族名（「Microsoft YaHei
/// Light」），Flutter 与 GDI+（桌面歌词）正是按这些名字解析的；若用排版族名
/// （name_id 16）会把这些字重合并成「Microsoft YaHei」，存档里已有的
/// 「Microsoft YaHei Light」反而在列表里找不到。没有 1 时才退 16。
fn family_name(face: &ttf_parser::Face<'_>) -> Option<String> {
    use ttf_parser::name_id;
    for id in [name_id::FAMILY, name_id::TYPOGRAPHIC_FAMILY] {
        let found = face
            .names()
            .into_iter()
            .find(|name| name.name_id == id && name.is_unicode())
            .and_then(|name| name.to_string());
        if found.is_some() {
            return found;
        }
    }
    None
}
