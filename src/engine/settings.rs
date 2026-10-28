//! Persisted indexing preferences shared by the desktop app and daemon.

use super::*;
use serde::{Deserialize, Serialize};

#[derive(Clone, Serialize, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct IndexSettings {
    pub automatic: bool,
    pub excluded: Vec<PathBuf>,
}

impl Default for IndexSettings {
    fn default() -> Self { Self { automatic: true, excluded: Vec::new() } }
}

impl IndexSettings {
    pub(super) fn load(dir: &Path) -> Result<Self, String> {
        match std::fs::read(dir.join("index-settings.json")) {
            Ok(data) => {
                let mut settings: Self = serde_json::from_slice(&data).map_err(|e| format!("无法读取索引设置：{e}"))?;
                settings.normalize()?;
                Ok(settings)
            }
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(Self::default()),
            Err(e) => Err(e.to_string()),
        }
    }

    fn normalize(&mut self) -> Result<(), String> {
        if self.excluded.len() > 256 { return Err("最多可排除 256 个文件夹。".into()); }
        for path in &mut self.excluded {
            if !path.is_absolute() || path.components().any(|part| matches!(part, std::path::Component::ParentDir)) {
                return Err("请选择完整的文件夹路径。".into());
            }
            *path = PathBuf::from(std::ffi::OsStr::from_bytes(&crate::live::normalize(path.as_os_str().as_bytes())));
            if path == Path::new("/") { return Err("不能排除整个内置硬盘。".into()); }
        }
        self.excluded.sort();
        self.excluded.dedup();
        Ok(())
    }
}

impl Engine {
    pub fn index_settings(&self) -> IndexSettings { self.s.settings.read().unwrap().clone() }

    pub fn update_index_settings(&self, mut settings: IndexSettings) -> Result<(), String> {
        if !self.s.owner() { return Err("请重新载入搜索引擎后再修改索引设置。".into()); }
        settings.normalize()?;
        let mut current = self.s.settings.write().unwrap();
        let data = serde_json::to_vec_pretty(&settings).map_err(|e| e.to_string())?;
        let temporary = self.s.dir.join("index-settings.json.new");
        std::fs::write(&temporary, data)
            .and_then(|_| std::fs::rename(&temporary, self.s.dir.join("index-settings.json")))
            .map_err(|e| format!("无法保存索引设置：{e}"))?;
        let resume = !current.automatic && settings.automatic;
        *walk::EXCLUDED.write().unwrap() = settings.excluded.iter().map(|path| path.as_os_str().as_bytes().to_vec()).collect();
        self.s.automatic.store(settings.automatic, Ordering::Release);
        *current = settings;
        if resume {
            let since = self.s.live.read().unwrap().as_ref().map_or(0, |live| live.event_id);
            self.s.watch(since);
        }
        let _ = self.s.wake.send(Vec::new());
        Ok(())
    }

    pub(super) fn configured_query(&self, query: &Query) -> Query {
        let mut query = query.clone();
        for path in &self.s.settings.read().unwrap().excluded {
            query.exclude_folder(path.as_os_str().as_bytes());
        }
        query
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn settings_reject_root_relative_and_parent_paths() {
        for path in ["/", "relative", "/Users/me/../other"] {
            let mut settings = IndexSettings { automatic: true, excluded: vec![path.into()] };
            assert!(settings.normalize().is_err(), "accepted {path}");
        }
        let mut settings = IndexSettings { automatic: false, excluded: vec!["/Users/me/cache/".into(), "/Users/me/cache".into()] };
        settings.normalize().unwrap();
        assert_eq!(settings.excluded, vec![PathBuf::from("/Users/me/cache")]);
        let restored: IndexSettings = serde_json::from_slice(&serde_json::to_vec(&settings).unwrap()).unwrap();
        assert!(!restored.automatic);
        assert_eq!(restored.excluded, settings.excluded);
    }

    #[test]
    fn settings_exclusion_applies_before_page_selection_and_totals() {
        let root = Listing { id: 0, names: b"skipkeep".to_vec(), ents: vec![
            RawEnt { name_off: 0, name_len: 4, kind: KIND_DIR, size: 0, mtime: 1, child: 1 },
            RawEnt { name_off: 4, name_len: 4, kind: KIND_DIR, size: 0, mtime: 1, child: 2 },
        ] };
        let folder = |id| Listing { id, names: b"report".to_vec(), ents: vec![
            RawEnt { name_off: 0, name_len: 6, kind: walk::KIND_FILE, size: 1, mtime: 1, child: NONE }
        ] };
        let live = Live::new(Index::build(vec![root, folder(1), folder(2)], 0, 0, b"/h"));
        let mut query = Query::parse("", "/h").unwrap();
        query.exclude_folder(b"/skip");
        let (hits, next) = browsing::desktop_page(&live, &[], &query, 0);
        assert_eq!(hits.len(), 2);
        assert!(next.is_none());
        assert!(hits.iter().all(|hit| !hit.path.starts_with("/skip")));
        let order = PageOrder { column: PageColumn::Name, ascending: true, directories_first: false };
        let page = paging::collect(&live, &[], &query, order, None, 1);
        assert_eq!(page.hits.len(), 1);
        assert!(page.has_more);
        assert_eq!(page.total, Some(2));
        let second = paging::collect(&live, &[], &query, order, page.hits.last(), 1);
        assert_eq!(second.hits.len(), 1);
        assert!(!second.has_more);
        assert_ne!(page.hits[0].path, second.hits[0].path);
    }
}
