//! Global keyset pagination keeps at most one page in the selection heap.
//! Paths for the complete result set are never retained by the desktop client.
use super::*;
use std::cmp::Ordering as Cmp;
use std::collections::BinaryHeap;
use std::ffi::{OsString, c_void};
use std::os::unix::ffi::OsStringExt;

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum PageColumn { Relevance, Name, Path, Kind, Size, Modified, Created }

#[derive(Clone, Copy)]
pub struct PageOrder {
    pub column: PageColumn,
    pub ascending: bool,
    pub directories_first: bool,
}

pub struct SearchPage {
    pub hits: Vec<Found>,
    pub has_more: bool,
    pub total: Option<usize>,
}

#[link(name = "CoreFoundation", kind = "framework")]
unsafe extern "C" {
    fn CFLocaleCopyCurrent() -> *const c_void;
    fn CFStringCreateWithBytes(allocator: *const c_void, bytes: *const u8, length: isize, encoding: u32, external: bool) -> *const c_void;
    fn CFStringGetLength(string: *const c_void) -> isize;
    fn CFStringCompareWithOptionsAndLocale(a: *const c_void, b: *const c_void, range: CFRange, options: usize, locale: *const c_void) -> isize;
    fn CFRelease(value: *const c_void);
}

#[repr(C)]
struct CFRange { location: isize, length: isize }
struct NativeString(*const c_void);
impl NativeString {
    fn new(text: &[u8]) -> Self {
        let text = String::from_utf8_lossy(text);
        Self(unsafe { CFStringCreateWithBytes(std::ptr::null(), text.as_ptr(), text.len() as isize, 0x08000100, false) })
    }
}
impl Drop for NativeString {
    fn drop(&mut self) { if !self.0.is_null() { unsafe { CFRelease(self.0) }; } }
}
struct Locale(*const c_void);
impl Drop for Locale {
    fn drop(&mut self) { if !self.0.is_null() { unsafe { CFRelease(self.0) }; } }
}

struct Candidate {
    hit: Found,
    text: Option<NativeString>,
    order: PageOrder,
    locale: *const c_void,
}
impl Candidate {
    fn new(hit: Found, order: PageOrder, locale: *const c_void) -> Self {
        let text = match order.column {
            PageColumn::Name => Some(NativeString::new(hit.path.file_name().unwrap_or(hit.path.as_os_str()).as_bytes())),
            PageColumn::Path => Some(NativeString::new(hit.path.as_os_str().as_bytes())),
            PageColumn::Kind => {
                let extension = hit.path.extension().unwrap_or_default().to_string_lossy();
                let text = if extension.eq_ignore_ascii_case("app") { "应用程序".into() }
                    else if hit.kind & 3 == KIND_DIR { "文件夹".into() }
                    else if extension.is_empty() { "文件".into() }
                    else { format!("{} 文件", extension.to_uppercase()) };
                Some(NativeString::new(text.as_bytes()))
            }
            _ => None,
        };
        Self { hit, text, order, locale }
    }
}
impl PartialEq for Candidate { fn eq(&self, other: &Self) -> bool { self.cmp(other) == Cmp::Equal } }
impl Eq for Candidate {}
impl PartialOrd for Candidate { fn partial_cmp(&self, other: &Self) -> Option<Cmp> { Some(self.cmp(other)) } }
impl Ord for Candidate {
    fn cmp(&self, other: &Self) -> Cmp {
        let (a, b) = (&self.hit, &other.hit);
        if self.order.directories_first {
            let comparison = (a.kind & 3 != KIND_DIR).cmp(&(b.kind & 3 != KIND_DIR));
            if comparison != Cmp::Equal { return comparison }
        }
        let comparison = match self.order.column {
            PageColumn::Relevance => b.score.cmp(&a.score),
            PageColumn::Size => a.size.cmp(&b.size),
            PageColumn::Modified => a.mtime.cmp(&b.mtime),
            PageColumn::Created => Cmp::Equal, // Creation dates are not stored in the name index.
            _ => {
                let (a, b) = (self.text.as_ref().unwrap().0, other.text.as_ref().unwrap().0);
                if a.is_null() || b.is_null() { self.hit.path.cmp(&other.hit.path) }
                else {
                    // Same numeric, case, width and forced-order rules as the
                    // desktop Foundation comparator; locale is pinned per page.
                    unsafe { CFStringCompareWithOptionsAndLocale(a, b, CFRange { location: 0, length: CFStringGetLength(a) }, 1 | 64 | 256 | 512, self.locale) }.cmp(&0)
                }
            }
        };
        let comparison = if self.order.column != PageColumn::Relevance && !self.order.ascending { comparison.reverse() } else { comparison };
        comparison.then_with(|| a.path.cmp(&b.path))
    }
}

pub(super) fn collect(internal: &Live, external: &[(PathBuf, Arc<Live>)], query: &Query,
                      order: PageOrder, after: Option<&Found>, limit: usize) -> SearchPage {
    let maximum = external.iter().map(|(_, live)| live.base.n).fold(internal.base.n, usize::max);
    if !query.tokens.is_empty() || maximum < 100_000 {
        return collect_range(internal, external, query, order, after, limit, None);
    }
    collect_parallel(internal, external, query, order, after, limit, maximum)
}

fn collect_parallel(internal: &Live, external: &[(PathBuf, Arc<Live>)], query: &Query,
                    order: PageOrder, after: Option<&Found>, limit: usize, maximum: usize) -> SearchPage {
    use rayon::prelude::*;
    let workers = rayon::current_num_threads().clamp(1, 8);
    let chunk = maximum.div_ceil(workers);
    (0..workers).into_par_iter().map(|part| {
        collect_range(internal, external, query, order, after, limit, Some((part * chunk, ((part + 1) * chunk).min(maximum))))
    }).reduce(|| SearchPage { hits: Vec::new(), has_more: false, total: Some(0) }, |left, right| {
        let locale = Locale(unsafe { CFLocaleCopyCurrent() });
        let total = left.total.unwrap_or(0) + right.total.unwrap_or(0);
        let mut has_more = left.has_more || right.has_more;
        let mut heap = BinaryHeap::<Candidate>::with_capacity(limit + 1);
        for hit in left.hits.into_iter().chain(right.hits) {
            let candidate = Candidate::new(hit, order, locale.0);
            if heap.len() < limit { heap.push(candidate); }
            else {
                has_more = true;
                if candidate < *heap.peek().unwrap() { *heap.peek_mut().unwrap() = candidate; }
            }
        }
        SearchPage { hits: heap.into_sorted_vec().into_iter().map(|candidate| candidate.hit).collect(), has_more, total: Some(total) }
    })
}

fn collect_range(internal: &Live, external: &[(PathBuf, Arc<Live>)], query: &Query,
                 order: PageOrder, after: Option<&Found>, limit: usize, range: Option<(usize, usize)>) -> SearchPage {
    // Every worker owns its locale and bounded heap. Only retained page rows
    // cross threads; the full path catalog is never materialized.
    let locale = Locale(unsafe { CFLocaleCopyCurrent() });
    let after = after.map(|hit| Candidate::new(hit.clone(), order, locale.0));
    let mut heap = BinaryHeap::<Candidate>::with_capacity(limit + 1);
    let mut total = 0usize;
    let mut visit = |hit: Found| {
        total += 1;
        let candidate = Candidate::new(hit, order, locale.0);
        if after.as_ref().is_some_and(|after| candidate <= *after) { return }
        if heap.len() < limit + 1 { heap.push(candidate); }
        else if heap.peek().is_some_and(|worst| candidate < *worst) {
            *heap.peek_mut().unwrap() = candidate;
        }
    };
    let sources = std::iter::once((None, internal)).chain(external.iter().map(|(root, live)| (Some(root.as_os_str().as_bytes()), live.as_ref())));
    for (root, live) in sources {
        let mut query = query.clone();
        if root.is_some_and(|root| !crate::volumes::scope_for_volume(&mut query, root)) { continue }
        if !query.tokens.is_empty() {
            // Use indexed candidate selection and the same typo/normalization
            // semantics as ordinary searches; only matching row IDs are held.
            query.limit = usize::MAX;
            let mut path = Vec::new();
            for hit in (Searcher { live }).search(&query) {
                let (path, kind, size, mtime) = if let Some(path) = hit.over {
                    let entry = live.over[&path];
                    (path, entry.kind, entry.size, entry.mtime)
                } else {
                    let index = hit.idx as usize;
                    live.base.path(index, &mut path);
                    (path.clone(), live.base.kind(index), live.base.size_of(index), live.base.mtime(index))
                };
                visit(Found { path: PathBuf::from(OsString::from_vec(path)), kind, size, mtime, score: hit.score });
            }
        } else {
            let (mut lo, mut hi) = (Searcher { live }).scope_range(&query).unwrap_or((0, 0));
            if let Some((start, end)) = range { lo = lo.max(start); hi = hi.min(end); }
            let mut path = Vec::new();
            // The front-coded index groups nearby paths. Visit the requested
            // end first so descending path selection does not replace the
            // entire heap for almost every following entry.
            for step in lo..hi {
                let index = if order.column == PageColumn::Path && !order.ascending { hi - 1 - (step - lo) } else { step };
                if live.is_dead(index as u32) { continue }
                let (kind, size, mtime) = (live.base.kind(index), live.base.size_of(index), live.base.mtime(index));
                if size < query.size.0 || size > query.size.1 || mtime < query.mtime.0 || mtime > query.mtime.1 { continue }
                live.base.path(index, &mut path);
                if let Some(score) = query.match_path(&path, kind, size, mtime) {
                    visit(Found { path: PathBuf::from(std::ffi::OsStr::from_bytes(&path)), kind, size, mtime, score });
                }
            }
            if range.is_some_and(|(start, _)| start != 0) { continue }
            for (index, (path, entry)) in live.flat.items.iter().enumerate() {
                if live.flat.masks[index] == 0 { continue }
                if let Some(score) = query.match_path(path, entry.kind, entry.size, entry.mtime) {
                    visit(Found { path: PathBuf::from(std::ffi::OsStr::from_bytes(path)), kind: entry.kind, size: entry.size, mtime: entry.mtime, score });
                }
            }
        }
    }
    let mut candidates = heap.into_sorted_vec();
    let has_more = candidates.len() > limit;
    candidates.truncate(limit);
    SearchPage { hits: candidates.into_iter().map(|candidate| candidate.hit).collect(), has_more, total: Some(total) }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture() -> Live {
        let names: &[(&str, u8, u64, u32)] = &[
            ("b10.txt", 0, 20, 8), ("b2.txt", 0, 20, 7), ("a.txt", 0, 30, 3),
            ("文件2.txt", 0, 10, 6), ("文件10.txt", 0, 10, 5), ("folder", 1, 0, 1),
            ("Example.app", 1, 0, 2), ("program.bin", 0, 30, 4),
        ];
        let mut bytes = Vec::new();
        let mut entries = Vec::new();
        for &(name, kind, size, mtime) in names {
            entries.push(RawEnt { name_off: bytes.len() as _, name_len: name.len() as _, kind, size, mtime, child: NONE });
            bytes.extend_from_slice(name.as_bytes());
        }
        Live::new(Index::build(vec![Listing { id: 0, names: bytes, ents: entries }], 0, 0, b"/h"))
    }

    #[test]
    fn global_keyset_pages_match_complete_order() {
        let live = fixture();
        let query = Query::parse("", "/h").unwrap();
        for column in [PageColumn::Name, PageColumn::Path, PageColumn::Kind, PageColumn::Size, PageColumn::Modified, PageColumn::Created, PageColumn::Relevance] {
            for ascending in [true, false] {
                for directories_first in [true, false] {
                    let order = PageOrder { column, ascending, directories_first };
                    let all = collect(&live, &[], &query, order, None, 100);
                    let mut loaded = Vec::new();
                    let mut after = None;
                    loop {
                        let page = collect_parallel(&live, &[], &query, order, after.as_ref(), 2, live.base.n);
                        assert!(page.hits.len() <= 2);
                        assert_eq!(page.total, Some(all.hits.len()));
                        after = page.hits.last().cloned();
                        loaded.extend(page.hits);
                        if !page.has_more { break }
                        assert!(after.is_some());
                    }
                    assert_eq!(loaded.iter().map(|hit| &hit.path).collect::<Vec<_>>(), all.hits.iter().map(|hit| &hit.path).collect::<Vec<_>>());
                    if directories_first {
                        let first_file = loaded.iter().position(|hit| hit.kind & 3 != KIND_DIR).unwrap();
                        assert!(loaded[first_file..].iter().all(|hit| hit.kind & 3 != KIND_DIR));
                    }
                }
            }
        }
        let order = PageOrder { column: PageColumn::Name, ascending: true, directories_first: false };
        let names = collect(&live, &[], &query, order, None, 100).hits;
        let position = |name: &str| names.iter().position(|hit| hit.path.file_name().unwrap() == name).unwrap();
        assert!(position("b2.txt") < position("b10.txt"));
        assert!(position("文件2.txt") < position("文件10.txt"));
        let mut filtered = query.clone();
        filtered.filter("ext", "txt", "/h").unwrap();
        let page = collect(&live, &[], &filtered, order, None, 2);
        assert_eq!(page.total, Some(5));
        assert!(page.hits.iter().all(|hit| hit.path.extension().unwrap() == "txt"));
    }

    #[test]
    fn real_index_pages_are_bounded() {
        let Some(path) = std::env::var_os("FSEARCH_BENCH_INDEX") else { return };
        let live = Live::lazy(Index::load(Path::new(&path)).expect("read-only real index"));
        let mut query = Query::parse("", "/").unwrap();
        query.limit = 3000;
        let started = Instant::now();
        let (first, next) = browsing::desktop_page(&live, &[], &query, 0);
        println!("real rows={}, first page={}, browse_us={}", live.base.n, first.len(), started.elapsed().as_micros());
        assert_eq!(first.len(), 3000);
        let (second, _) = browsing::desktop_page(&live, &[], &query, next.unwrap());
        assert_eq!(second.len(), 3000);
        let paths: std::collections::HashSet<_> = first.iter().map(|hit| &hit.path).collect();
        assert!(second.iter().all(|hit| !paths.contains(&hit.path)));
        for (label, column) in [("size", PageColumn::Size), ("modified", PageColumn::Modified),
                                ("name", PageColumn::Name), ("path", PageColumn::Path), ("kind", PageColumn::Kind)] {
            let started = Instant::now();
            let page = collect(&live, &[], &query, PageOrder { column, ascending: false, directories_first: false }, None, 3000);
            println!("global {label} page={}, total={}, elapsed_ms={}", page.hits.len(), page.total.unwrap(), started.elapsed().as_millis());
            assert_eq!(page.hits.len(), 3000);
            assert!(page.has_more);
            if column == PageColumn::Size { assert!(page.hits.windows(2).all(|hits| hits[0].size >= hits[1].size)); }
        }
    }
}
