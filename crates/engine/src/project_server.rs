//! project-server swap point. v0 keeps local FS via `projects` / `project_vcs`.
//! When a remote backend is configured, the same client service actions are served here.
use serde_json::{json, Value};
use std::path::Path;

/// Optional remote base URL from environment. Empty means local-only.
pub fn remote_base() -> Option<String> {
    std::env::var("TUKURIUM_PROJECT_SERVER")
        .ok()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
}

/// Handle actions only when a remote project-server is configured.
/// Currently returns a clear stub error so clients do not silently fall through.
pub fn handle(_data_root: &Path, action: &str, body: &Value) -> Result<Option<Value>, String> {
    let Some(base) = remote_base() else {
        return Ok(None);
    };
    if !action.starts_with("project") && action != "projects" && action != "create_project" {
        return Ok(None);
    }
    let _ = body;
    Err(format!(
        "project-server is configured ({base}) but remote proxy is not implemented yet; unset TUKURIUM_PROJECT_SERVER to use local projects"
    ))
}

pub fn status() -> Value {
    match remote_base() {
        Some(base) => json!({"mode":"remote","base":base,"ready":false}),
        None => json!({"mode":"local","ready":true}),
    }
}
