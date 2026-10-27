//! Versioned, length-framed desktop rows. JSON remains the control protocol;
//! large result arrays avoid per-number/string JSON decoding in Foundation.
use super::{DESKTOP_TYPES, Found, Query, Value, json, put};
use std::collections::HashMap;
use std::os::unix::ffi::OsStrExt;

pub(super) struct Classifier {
    filters: Vec<Query>,
    masks: HashMap<(u8, Vec<u8>), u8>,
}

impl Classifier {
    pub(super) fn new() -> Self {
        let filters = DESKTOP_TYPES.iter().map(|name| {
            let mut query = Query::parse("", "").expect("empty query");
            query.filter("type", name, "").expect("desktop file type");
            if !matches!(*name, "app" | "other") { query.filter("kind", "file", "").expect("file kind"); }
            query
        }).collect();
        Self { filters, masks: HashMap::new() }
    }

    pub(super) fn mask(&mut self, hit: &Found) -> u8 {
        let path = hit.path.as_os_str().as_bytes();
        let extension = path.iter().rposition(|&b| b == b'.' || b == b'/')
            .filter(|&i| path[i] == b'.').map(|i| path[i..].to_ascii_lowercase()).unwrap_or_default();
        let kind = hit.kind & 3;
        *self.masks.entry((kind, extension)).or_insert_with(|| {
            self.filters.iter().enumerate().fold(0, |mask, (i, query)| {
                mask | if query.match_path(path, kind, 0, 0).is_some() { 1 << i } else { 0 }
            })
        })
    }
}

pub(super) fn write(out: &mut Vec<u8>, hits: &[Found], id: &Value, took_us: u64) {
    write_page(out, hits, id, took_us, None, Some(hits.len()));
}

pub(super) fn write_page(out: &mut Vec<u8>, hits: &[Found], id: &Value, took_us: u64, next: Option<Value>, total: Option<usize>) {
    // Record: path byte length u32, kind u8, mask u8, reserved u16,
    // size u64, mtime u32, then UTF-8 path bytes. Integers are little-endian.
    let bytes: usize = hits.iter().map(|hit| 20 + hit.path.to_string_lossy().len()).sum();
    put(out, &json!({"ok": true, "id": id, "binary_version": 1,
        "binary_bytes": bytes, "count": hits.len(), "types": DESKTOP_TYPES, "took_us": took_us, "next": next, "total": total}));
    out.reserve(bytes);
    let mut classifier = Classifier::new();
    for hit in hits {
        let path = hit.path.to_string_lossy();
        out.extend_from_slice(&(path.len() as u32).to_le_bytes());
        out.push(hit.kind & 3);
        out.push(classifier.mask(hit));
        out.extend_from_slice(&[0, 0]);
        out.extend_from_slice(&hit.size.to_le_bytes());
        out.extend_from_slice(&hit.mtime.to_le_bytes());
        out.extend_from_slice(path.as_bytes());
    }
}
