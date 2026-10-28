//! Storage permissions and independently managed disk indexes for settings.

use fsearch::Engine;
use serde_json::{Value, json};

pub fn status(engine: &Engine) -> Value {
    json!({
        "ok": true,
        "full_disk_access": fsearch::has_full_disk_access(),
        "active_full_disk_access": engine.status().full_disk_access,
        "internal": engine.internal_index_status(),
        "volumes": engine.external_storage_status(),
        "settings": engine.index_settings(),
    })
}
