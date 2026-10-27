//! Independently saved, explicitly built indexes for individual mounted disks.

use crate::engine::Found;
use crate::index::Index;
use crate::live::Live;
use crate::query::{Query, Searcher};
use crate::walk::{self, KIND_DIR, Listing, NONE, RawEnt};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::collections::HashMap;
use std::ffi::{CStr, CString};
use std::hash::{Hash, Hasher};
use std::os::unix::ffi::OsStrExt;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

#[derive(Clone, Serialize, Deserialize)]
struct Record {
    id: String,
    path: PathBuf,
    entries: usize,
    indexed_at: u64,
}

#[derive(Default)]
struct State {
    records: Vec<Record>,
    indexes: HashMap<String, Arc<Live>>,
    jobs: HashMap<String, String>,
    readable: HashMap<String, bool>,
}

#[derive(Clone)]
pub(crate) struct VolumeIndexes {
    dir: PathBuf,
    home: String,
    state: Arc<Mutex<State>>,
}

impl VolumeIndexes {
    pub fn new(dir: &Path, home: &str) -> Result<Self, String> {
        let dir = dir.join("volumes");
        std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
        let records: Vec<Record> = match std::fs::read(dir.join("registered.json")) {
            Ok(data) => serde_json::from_slice(&data).map_err(|e| format!("无法读取外置磁盘索引记录：{e}"))?,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Vec::new(),
            Err(e) => return Err(e.to_string()),
        };
        let mut state = State { records, ..State::default() };
        for record in &state.records {
            if let Some(index) = Index::load(&dir.join(format!("{}.bin", record.id))) {
                state.indexes.insert(record.id.clone(), Arc::new(Live::lazy(index)));
            }
        }
        Ok(Self { dir, home: home.into(), state: Arc::new(Mutex::new(state)) })
    }

    pub fn status(&self) -> Vec<Value> {
        let mounts = mounted();
        let state = self.state.lock().unwrap();
        mounts.into_iter().map(|(path, id)| {
            let record = state.records.iter().find(|r| r.id == id && r.path == path);
            let job = state.jobs.get(&id);
            json!({
                "name": path.file_name().unwrap_or_default().to_string_lossy(),
                "path": path.to_string_lossy(),
                "readable": state.readable.get(&id),
                "included": record.is_some() && state.indexes.contains_key(&id),
                "building": job.is_some_and(|s| s == "building"),
                "error": job.filter(|s| s.as_str() != "building"),
                "entries": record.map(|r| r.entries),
                "indexed_at": record.map(|r| r.indexed_at),
            })
        }).collect()
    }

    pub fn check_access(&self, path: &Path) -> Result<(), String> {
        let id = validate(path)?;
        let result = std::fs::read_dir(path);
        self.state.lock().unwrap().readable.insert(id, result.is_ok());
        result.map(|_| ()).map_err(|e| format!("无法读取此磁盘，请允许访问可移除宗卷或网络宗卷后重试。{e}"))
    }

    pub fn rebuild(&self, path: &Path) -> Result<(), String> {
        let id = validate(path)?;
        self.check_access(path)?;
        {
            let mut state = self.state.lock().unwrap();
            if state.jobs.get(&id).is_some_and(|s| s == "building") {
                return Err("此磁盘正在建立索引。".into());
            }
            state.jobs.insert(id.clone(), "building".into());
        }
        let this = self.clone();
        let path = path.to_path_buf();
        let worker_id = id.clone();
        if let Err(error) = std::thread::Builder::new().name("fsearch-volume-index".into()).spawn(move || {
            let result = this.build(&path, &worker_id);
            let mut state = this.state.lock().unwrap();
            match result {
                Ok(()) => { state.jobs.remove(&worker_id); }
                Err(error) => { state.jobs.insert(worker_id, error); }
            }
        }) {
            self.state.lock().unwrap().jobs.insert(id, error.to_string());
            return Err(error.to_string());
        }
        Ok(())
    }

    fn build(&self, path: &Path, id: &str) -> Result<(), String> {
        let root = path.as_os_str().as_bytes();
        let components: Vec<_> = root.split(|&b| b == b'/').filter(|p| !p.is_empty()).collect();
        let shift = components.len() as u32;
        let mut listings: Vec<_> = components.iter().enumerate().map(|(i, name)| Listing {
            id: i as u32,
            names: name.to_vec(),
            ents: vec![RawEnt { name_off: 0, name_len: name.len() as u16, kind: KIND_DIR, size: 0, mtime: 0, child: i as u32 + 1 }],
        }).collect();
        for mut listing in walk::scan_external(root, 4) {
            listing.id += shift;
            for entry in listing.ents.iter_mut().filter(|e| e.child != NONE) { entry.child += shift; }
            listings.push(listing);
        }
        // A removed/replaced disk must never overwrite its previous good index.
        if validate(path)? != id { return Err("磁盘已断开或发生变化，请重新选择磁盘。".into()); }
        std::fs::read_dir(path).map_err(|e| format!("磁盘读取中断：{e}"))?;
        let index = Index::build(listings, 0, crate::query::now_secs(), self.home.as_bytes());
        let file = self.dir.join(format!("{id}.bin"));
        index.save(&file).map_err(|e| e.to_string())?;
        let index = Index::load(&file).ok_or("无法载入新建的磁盘索引。")?;
        let record = Record { id: id.into(), path: path.into(), entries: index.n.saturating_sub(shift as usize), indexed_at: crate::query::now_secs() as u64 };
        let mut state = self.state.lock().unwrap();
        let mut records = state.records.clone();
        records.retain(|r| r.id != id);
        records.push(record);
        let encoded = serde_json::to_vec_pretty(&records).map_err(|e| e.to_string())?;
        let temporary = self.dir.join("registered.json.new");
        std::fs::write(&temporary, encoded).and_then(|_| std::fs::rename(&temporary, self.dir.join("registered.json"))).map_err(|e| e.to_string())?;
        state.records = records;
        state.indexes.insert(id.into(), Arc::new(Live::lazy(index)));
        Ok(())
    }

    pub(crate) fn active(&self) -> Vec<(PathBuf, Arc<Live>)> {
        let mounts = mounted();
        let state = self.state.lock().unwrap();
        mounts.into_iter().filter_map(|(path, id)| {
            state.records.iter().find(|r| r.id == id && r.path == path)?;
            Some((path, state.indexes.get(&id)?.clone()))
        }).collect()
    }

    pub fn search(&self, q: &Query) -> Vec<Found> {
        let mut found = Vec::new();
        for (path, live) in self.active() {
            let mut scoped = q.clone();
            let root = path.as_os_str().as_bytes();
            if !scope_for_volume(&mut scoped, root) { continue }
            for hit in (Searcher { live: &live }).search(&scoped) {
                let mut bytes = Vec::new();
                live.base.path(hit.idx as usize, &mut bytes);
                let i = hit.idx as usize;
                found.push(Found { path: PathBuf::from(std::ffi::OsStr::from_bytes(&bytes)), kind: live.base.kind(i), size: live.base.size_of(i), mtime: live.base.mtime(i), score: hit.score });
            }
        }
        found
    }

    pub fn content_paths(&self, q: &Query) -> Vec<Vec<u8>> {
        let mut paths = Vec::new();
        for (path, live) in self.active() {
            let mut scoped = q.clone_for_scan();
            if scope_for_volume(&mut scoped, path.as_os_str().as_bytes()) {
                paths.extend(crate::content::scan_paths(&live, scoped));
            }
        }
        paths
    }
}

pub(crate) fn scope_for_volume(q: &mut Query, root: &[u8]) -> bool {
    let within = |path: &[u8], parent: &[u8]| parent == b"/" || (path.starts_with(parent) && (path.len() == parent.len() || path[parent.len()] == b'/'));
    match &q.scope {
        Some(scope) if within(scope, root) => true,
        Some(scope) if !within(root, scope) => false,
        _ => { q.scope = Some(root.to_vec()); true }
    }
}

fn mounted() -> Vec<(PathBuf, String)> {
    // The mount table remains readable when a disk's root has no permission;
    // such disks must still be listed so the user can authorize them.
    let count = unsafe { libc::getfsstat(std::ptr::null_mut(), 0, libc::MNT_NOWAIT) };
    if count <= 0 { return Vec::new() }
    let mut buffer: Vec<libc::statfs> = (0..count + 8).map(|_| unsafe { std::mem::zeroed() }).collect();
    let count = unsafe { libc::getfsstat(buffer.as_mut_ptr(), std::mem::size_of_val(buffer.as_slice()) as _, libc::MNT_NOWAIT) };
    let mut mounts: Vec<_> = buffer.iter().take(count.max(0) as usize).filter_map(|stat| {
        let name = unsafe { CStr::from_ptr(stat.f_mntonname.as_ptr()) }.to_bytes();
        if !walk::external_volume(name) { return None }
        let path = PathBuf::from(std::ffi::OsStr::from_bytes(name));
        let id = validate(&path).unwrap_or_else(|_| format!("unreadable:{}", path.display()));
        Some((path, id))
    }).collect();
    mounts.sort_by(|a, b| a.0.cmp(&b.0));
    mounts
}

fn validate(path: &Path) -> Result<String, String> {
    let root = path.as_os_str().as_bytes();
    if !walk::external_volume(root) || !path.symlink_metadata().is_ok_and(|m| m.is_dir()) || !walk::is_mount(root) {
        return Err("请选择 /Volumes 下已连接磁盘的根目录。".into());
    }
    let cpath = CString::new(root).map_err(|e| e.to_string())?;
    let mut attrs: libc::attrlist = unsafe { std::mem::zeroed() };
    attrs.bitmapcount = libc::ATTR_BIT_MAP_COUNT;
    attrs.volattr = 0x8004_0000; // ATTR_VOL_INFO | ATTR_VOL_UUID
    let mut buffer = [0u8; 20];
    let result = unsafe { libc::getattrlist(cpath.as_ptr(), (&raw mut attrs).cast(), buffer.as_mut_ptr().cast(), buffer.len(), 0) };
    if result == 0 && buffer[4..].iter().any(|b| *b != 0) {
        return Ok(buffer[4..].iter().map(|b| format!("{b:02x}")).collect());
    }
    // Network filesystems may not have a volume UUID. Their mount source is
    // stable across reconnects, unlike a device number or mount-time fsid.
    let mut stat: libc::statfs = unsafe { std::mem::zeroed() };
    if unsafe { libc::statfs(cpath.as_ptr(), &mut stat) } != 0 { return Err(std::io::Error::last_os_error().to_string()) }
    let source = unsafe { CStr::from_ptr(stat.f_mntfromname.as_ptr()) };
    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    source.to_bytes().hash(&mut hasher);
    Ok(format!("network-{:016x}", hasher.finish()))
}
