//! Explicit internal-disk rebuilds. Keep the old index searchable until the
//! replacement has been fully scanned and saved successfully.

use super::*;
use serde_json::{Value, json};

#[derive(Default)]
pub(super) struct Maintenance {
    requested: AtomicBool,
    state: Mutex<(bool, Option<String>, Option<u64>)>,
}

impl Maintenance {
    pub fn request(&self, shared: &Shared) -> Result<(), String> {
        if !shared.owner() { return Err("当前搜索引擎没有索引写入权限，请重新载入后重试。".into()); }
        if shared.live.read().unwrap().is_none() { return Err("首次索引仍在建立，请完成后重试。".into()); }
        let mut state = self.state.lock().unwrap();
        if state.0 { return Err("内置硬盘索引正在重建。".into()); }
        *state = (true, None, state.2);
        self.requested.store(true, Ordering::Relaxed);
        let _ = shared.wake.send(Vec::new());
        Ok(())
    }

    pub fn status(&self) -> Value {
        let state = self.state.lock().unwrap();
        json!({"building": state.0, "error": state.1, "indexed_at": state.2})
    }
}

pub(super) fn run(shared: &Shared) {
    if !shared.maintenance.requested.swap(false, Ordering::Relaxed) { return }
    let result = (|| -> Result<(), String> {
        let since = fsevents::current_id();
        let listings = walk::scan_disk(SCAN_THREADS);
        let index = Index::build(listings, since, crate::query::now_secs(), shared.home.as_bytes());
        let file = shared.dir.join("index.bin");
        index.save(&file).map_err(|e| e.to_string())?;
        let index = Index::load(&file).ok_or("无法载入新建的内置硬盘索引。")?;
        *shared.live.write().unwrap() = Some(Live::lazy(index));
        note_skipped(&shared.dir);
        let _ = shared.content_tx.send((Vec::new(), vec![shared.home.as_bytes().to_vec()]));
        Ok(())
    })();
    let mut state = shared.maintenance.state.lock().unwrap();
    state.0 = false;
    match result {
        Ok(()) => { state.1 = None; state.2 = Some(crate::query::now_secs() as u64); }
        Err(error) => { state.1 = Some(error); }
    }
    release_memory();
}
