use super::*;
use fsearch::{PageColumn, PageOrder};
use std::hash::{Hash, Hasher};

pub(super) fn run(request: &Value, engine: &Engine) -> Result<Reply, String> {
    let mut fields = request.clone();
    let object = fields.as_object_mut().ok_or("无效的搜索请求。")?;
    for key in ["cursor", "sort", "ascending", "directories_first", "id"] { object.remove(key); }
    let (mut query, selectors) = parse_request(&fields, engine.home())?;
    if query.grep.is_some() || !selectors.is_empty() { return Err("按需模式支持文件名搜索和文件筛选。".into()) }
    let limit = request.get("limit").and_then(Value::as_u64).unwrap_or(3000).clamp(1, 3000) as usize;
    query.limit = limit;
    let column = match request.get("sort").and_then(Value::as_str).unwrap_or("relevance") {
        "relevance" => PageColumn::Relevance, "name" => PageColumn::Name, "path" => PageColumn::Path,
        "kind" => PageColumn::Kind, "size" => PageColumn::Size, "modified" => PageColumn::Modified,
        "created" => PageColumn::Created, _ => return Err("无法识别的排序方式。".into()),
    };
    let order = PageOrder { column, ascending: request.get("ascending").and_then(Value::as_bool).unwrap_or(true),
        directories_first: request.get("directories_first").and_then(Value::as_bool).unwrap_or(false) };
    // Bind opaque continuation data to exactly the same filters/order.
    let mut signature = request.clone();
    signature.as_object_mut().unwrap().insert("index_settings".into(), serde_json::to_value(engine.index_settings()).map_err(|e| e.to_string())?);
    for key in ["cursor", "id"] { signature.as_object_mut().unwrap().remove(key); }
    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    signature.to_string().hash(&mut hasher);
    let key = format!("{:016x}", hasher.finish());
    let cursor = request.get("cursor").filter(|value| !value.is_null());
    if cursor.is_some_and(|cursor| cursor.get("key").and_then(Value::as_str) != Some(key.as_str())) {
        return Err("搜索条件已改变，请重新搜索。".into());
    }
    let started = Instant::now();
    if query.tokens.is_empty() && column == PageColumn::Relevance {
        let position = match cursor {
            Some(cursor) => cursor.get("position").and_then(Value::as_u64).ok_or("分页位置无效，请重新搜索。")? as usize,
            None => 0,
        };
        let (hits, next) = engine.desktop_browse_ordered(&query, position, order.directories_first)?;
        let next = next.map(|position| json!({"key": key, "position": position}));
        return Ok(Reply::DesktopPage(hits, started.elapsed().as_micros() as u64, next, None));
    }
    let after = cursor.map(|cursor| -> Result<Found, String> {
        let after = cursor.get("after").ok_or("分页位置无效，请重新搜索。")?;
        Ok(Found {
            path: PathBuf::from(after.get("path").and_then(Value::as_str).ok_or("分页路径无效。")?),
            kind: after.get("kind").and_then(Value::as_u64).filter(|&value| value <= 3).ok_or("分页种类无效。")? as u8,
            size: after.get("size").and_then(Value::as_u64).ok_or("分页大小无效。")?,
            mtime: after.get("mtime").and_then(Value::as_u64).filter(|&value| value <= u32::MAX as u64).ok_or("分页时间无效。")? as u32,
            score: after.get("score").and_then(Value::as_i64).and_then(|value| i32::try_from(value).ok()).ok_or("分页排序值无效。")?,
        })
    }).transpose()?;
    let page = engine.search_page(&query, order, after.as_ref(), limit)?;
    let next = if page.has_more {
        page.hits.last().map(|hit| json!({"key": key, "after": {
            "path": hit.path.to_string_lossy(), "kind": hit.kind & 3, "size": hit.size, "mtime": hit.mtime, "score": hit.score
        }}))
    } else { None };
    Ok(Reply::DesktopPage(page.hits, started.elapsed().as_micros() as u64, next, page.total))
}
