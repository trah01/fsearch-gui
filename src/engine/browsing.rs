//! Cursor-based enumeration reads the existing indexes in bounded batches;
//! it never repeats a top-k search over all preceding pages.

use super::*;
use std::os::unix::ffi::{OsStrExt, OsStringExt};

const POSITION_BITS: usize = 48;
const FILE_PHASE: usize = 1usize << 63;
const POSITION_MASK: usize = (1usize << POSITION_BITS) - 1;

pub(super) fn page(internal: &Live, external: &[(PathBuf, Arc<Live>)], query: &Query, cursor: usize) -> (Vec<Found>, Option<usize>) {
    collect(internal, external, query, cursor, false, 2000, None)
}

pub(super) fn desktop_page(internal: &Live, external: &[(PathBuf, Arc<Live>)], query: &Query, cursor: usize) -> (Vec<Found>, Option<usize>) {
    collect(internal, external, query, cursor, false, 3000, None)
}

/// Directory priority is two bounded index traversals, not a global top-k.
/// Keep the group in the cursor so no file can precede remaining directories.
pub(super) fn desktop_directories_first(internal: &Live, external: &[(PathBuf, Arc<Live>)], query: &Query, cursor: usize) -> (Vec<Found>, Option<usize>) {
    let files = cursor & FILE_PHASE != 0 || !query.kind_ok(KIND_DIR);
    let includes_files = (0..=3).any(|kind| kind != KIND_DIR && query.kind_ok(kind));
    let position = cursor & !FILE_PHASE;
    let (hits, next) = collect(internal, external, query, position, false, 3000, Some(!files));
    let next = match next {
        Some(next) => Some(next | if files { FILE_PHASE } else { 0 }),
        None if !files && includes_files => Some(FILE_PHASE),
        None => None,
    };
    (hits, next)
}

pub(super) fn all(internal: &Live, external: &[(PathBuf, Arc<Live>)], query: &Query) -> Vec<Found> {
    let (mut found, _) = collect(internal, external, query, 0, true, 2000, None);
    if !query.tokens.is_empty() {
        found.sort_by(|a, b| b.score.cmp(&a.score).then_with(|| a.path.cmp(&b.path)));
    }
    found
}

fn collect(internal: &Live, external: &[(PathBuf, Arc<Live>)], query: &Query, cursor: usize, all: bool, page_limit: usize, directories: Option<bool>) -> (Vec<Found>, Option<usize>) {
    let mut sources: Vec<(Option<&[u8]>, &Live)> = vec![(None, internal)];
    sources.extend(external.iter().map(|(path, live)| (Some(path.as_os_str().as_bytes()), live.as_ref())));
    let mut source = cursor >> POSITION_BITS;
    let mut position = cursor & POSITION_MASK;
    let mut found = Vec::new();
    let limit = query.limit.clamp(1, page_limit);
    let started = Instant::now();
    let mut inspected = 0usize;
    while source < sources.len() {
        let (root, live) = sources[source];
        let mut query = query.clone();
        if root.is_some_and(|root| !crate::volumes::scope_for_volume(&mut query, root)) {
            source += 1;
            position = 0;
            continue;
        }
        let base = &live.base;
        let (lo, hi) = (Searcher { live }).scope_range(&query).unwrap_or((base.n, base.n));
        if position < base.n { position = position.max(lo); }
        let total = base.n + live.flat.items.len();
        while position < total {
            if position >= hi && position < base.n { position = base.n; continue }
            let index = position;
            position += 1;
            inspected += 1;
            let entry = if index < base.n {
                let (kind, size, mtime) = (base.kind(index), base.size_of(index), base.mtime(index));
                if live.is_dead(index as u32) || !metadata_matches(kind, size, mtime, &query, directories) { None }
                else {
                    let mut path = Vec::new();
                    base.path(index, &mut path);
                    Some((path, kind, size, mtime))
                }
            } else {
                let index = index - base.n;
                if live.flat.masks[index] == 0 { None }
                else {
                    let (path, entry) = &live.flat.items[index];
                    metadata_matches(entry.kind, entry.size, entry.mtime, &query, directories)
                        .then(|| (path.clone(), entry.kind, entry.size, entry.mtime))
                }
            };
            if let Some((path, kind, size, mtime)) = entry {
                if let Some(score) = query.match_path(&path, kind, size, mtime) {
                    // Transfer the reconstructed path rather than allocating
                    // and copying it a second time for every indexed entry.
                    found.push(Found { path: PathBuf::from(std::ffi::OsString::from_vec(path)), kind, size, mtime, score });
                }
            }
            if !all && (found.len() >= limit || (inspected % 256 == 0 && started.elapsed() >= Duration::from_millis(25))) {
                let next = if position < total { Some((source << POSITION_BITS) | position) }
                else if source + 1 < sources.len() { Some((source + 1) << POSITION_BITS) }
                else { None };
                return (found, next);
            }
        }
        source += 1;
        position = 0;
    }
    (found, None)
}

fn metadata_matches(kind: u8, size: u64, mtime: u32, query: &Query, directories: Option<bool>) -> bool {
    query.kind_ok(kind) && directories.is_none_or(|directories| (kind & 3 == KIND_DIR) == directories)
        && size >= query.size.0 && size <= query.size.1 && mtime >= query.mtime.0 && mtime <= query.mtime.1
}
