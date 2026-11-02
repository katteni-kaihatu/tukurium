//! Local project resource catalog (folders, meshes, materials, textures, scripts).
//! Stored under the project directory (or workspace-resources when no project).
use serde_json::{json, Value};
use std::fs;
use std::path::{Path, PathBuf};

use crate::projects::{meta_path, project_dir, read_display_name, validate_slug};

const ROOT_ID: &str = "r0";
const KINDS: &[&str] = &["folder", "model", "material", "image", "script", "shader", "package", "kokostate"];

fn workspace_root(data_root: &Path) -> PathBuf {
    data_root.join("workspace-resources")
}

fn catalog_dir(data_root: &Path, slug: Option<&str>) -> Result<PathBuf, String> {
    match slug {
        Some(s) if !s.is_empty() && s != "_workspace" => {
            validate_slug(s)?;
            if !meta_path(data_root, s).is_file() {
                return Err("Project not found".into());
            }
            Ok(project_dir(data_root, s).join("resources"))
        }
        _ => Ok(workspace_root(data_root)),
    }
}

fn catalog_path(dir: &Path) -> PathBuf {
    dir.join("catalog.json")
}

fn files_dir(dir: &Path) -> PathBuf {
    dir.join("files")
}

fn default_catalog(root_name: &str) -> Value {
    json!({
        "root_name": root_name,
        "items": [{
            "id": ROOT_ID,
            "kind": "folder",
            "name": root_name,
            "parent": null,
        }]
    })
}

fn load_catalog(dir: &Path, root_name: &str) -> Result<Value, String> {
    let path = catalog_path(dir);
    if !path.is_file() {
        let catalog = default_catalog(root_name);
        save_catalog(dir, &catalog)?;
        return Ok(catalog);
    }
    let bytes = fs::read(&path).map_err(|e| e.to_string())?;
    let mut catalog: Value = serde_json::from_slice(&bytes).map_err(|e| e.to_string())?;
    ensure_root(&mut catalog, root_name);
    Ok(catalog)
}

fn ensure_root(catalog: &mut Value, root_name: &str) {
    let items = catalog
        .as_object_mut()
        .map(|o| o.entry("items").or_insert_with(|| json!([])))
        .and_then(|v| v.as_array_mut());
    let Some(items) = items else { return };
    let has_root = items.iter().any(|x| x["id"].as_str() == Some(ROOT_ID));
    if !has_root {
        items.insert(
            0,
            json!({
                "id": ROOT_ID,
                "kind": "folder",
                "name": root_name,
                "parent": null,
            }),
        );
    }
    if let Some(root) = items.iter_mut().find(|x| x["id"].as_str() == Some(ROOT_ID)) {
        if root["name"].as_str().unwrap_or("").is_empty() {
            root["name"] = json!(root_name);
        }
    }
    catalog["root_name"] = json!(root_name);
}

fn save_catalog(dir: &Path, catalog: &Value) -> Result<(), String> {
    fs::create_dir_all(dir).map_err(|e| e.to_string())?;
    fs::create_dir_all(files_dir(dir)).map_err(|e| e.to_string())?;
    let path = catalog_path(dir);
    let tmp = dir.join("catalog.json.tmp");
    fs::write(&tmp, serde_json::to_vec_pretty(catalog).unwrap()).map_err(|e| e.to_string())?;
    fs::rename(tmp, path).map_err(|e| e.to_string())
}

fn resolve_root_name(data_root: &Path, slug: Option<&str>) -> String {
    match slug {
        Some(s) if !s.is_empty() && s != "_workspace" => {
            read_display_name(data_root, s).unwrap_or_else(|| s.to_string())
        }
        _ => "Workspace".into(),
    }
}

fn validate_kind(kind: &str) -> Result<(), String> {
    if KINDS.contains(&kind) {
        Ok(())
    } else {
        Err(format!("Unsupported resource kind: {kind}"))
    }
}

fn validate_id(id: &str) -> Result<(), String> {
    if id.is_empty() || id.len() > 64 || !id.chars().all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
    {
        Err("Invalid resource id".into())
    } else {
        Ok(())
    }
}

fn parent_ok(items: &[Value], parent: Option<&str>, self_id: &str) -> Result<(), String> {
    let Some(pid) = parent else {
        return if self_id == ROOT_ID {
            Ok(())
        } else {
            Err("Only the root folder may have a null parent".into())
        };
    };
    if pid == self_id {
        return Err("Resource cannot be its own parent".into());
    }
    let folder = items.iter().find(|x| x["id"].as_str() == Some(pid));
    match folder {
        Some(f) if f["kind"].as_str() == Some("folder") => Ok(()),
        Some(_) => Err("Parent must be a folder".into()),
        None => Err("Parent folder not found".into()),
    }
}

/// Write a binary blob into resources/files and return the relative file name.
pub fn store_file(data_root: &Path, slug: Option<&str>, id: &str, ext: &str, bytes: &[u8]) -> Result<String, String> {
    validate_id(id)?;
    if ext.is_empty() || ext.len() > 8 || !ext.chars().all(|c| c.is_ascii_alphanumeric()) {
        return Err("Invalid file extension".into());
    }
    if bytes.len() > 128 * 1024 * 1024 {
        return Err("File exceeds 128 MiB".into());
    }
    let dir = catalog_dir(data_root, slug)?;
    fs::create_dir_all(files_dir(&dir)).map_err(|e| e.to_string())?;
    let name = format!("{id}.{ext}");
    let path = files_dir(&dir).join(&name);
    let tmp = path.with_extension(format!("{ext}.tmp"));
    fs::write(&tmp, bytes).map_err(|e| e.to_string())?;
    fs::rename(tmp, path).map_err(|e| e.to_string())?;
    Ok(name)
}

pub fn file_path(data_root: &Path, slug: Option<&str>, file: &str) -> Result<PathBuf, String> {
    if file.is_empty()
        || file.contains("..")
        || file.contains('/')
        || file.contains('\\')
        || !file
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_' || c == '.')
    {
        return Err("Invalid resource file name".into());
    }
    let dir = catalog_dir(data_root, slug)?;
    let path = files_dir(&dir).join(file);
    if !path.is_file() {
        return Err("Resource file not found".into());
    }
    Ok(path)
}

pub fn list(data_root: &Path, slug: Option<&str>) -> Result<Value, String> {
    let dir = catalog_dir(data_root, slug)?;
    let root_name = resolve_root_name(data_root, slug);
    let catalog = load_catalog(&dir, &root_name)?;
    Ok(json!({
        "scope": slug.unwrap_or("_workspace"),
        "local": true,
        "root_name": catalog["root_name"],
        "items": catalog["items"],
        "files_dir": files_dir(&dir).to_string_lossy(),
    }))
}

pub fn upsert(data_root: &Path, slug: Option<&str>, body: &Value) -> Result<Value, String> {
    let item = body.get("item").ok_or("Missing item")?;
    let id = item["id"].as_str().ok_or("Missing item id")?;
    validate_id(id)?;
    let kind = item["kind"].as_str().ok_or("Missing kind")?;
    validate_kind(kind)?;
    let name = item["name"].as_str().unwrap_or("").trim();
    if name.is_empty() || name.len() > 80 {
        return Err("Name must be 1–80 characters".into());
    }
    let parent = item["parent"].as_str();
    let dir = catalog_dir(data_root, slug)?;
    let root_name = resolve_root_name(data_root, slug);
    let mut catalog = load_catalog(&dir, &root_name)?;
    let items = catalog["items"].as_array_mut().ok_or("Corrupt catalog")?;
    parent_ok(items, parent, id)?;
    if id == ROOT_ID && kind != "folder" {
        return Err("Root must remain a folder".into());
    }
    let mut stored = item.clone();
    stored["name"] = json!(name);
    if let Some(idx) = items.iter().position(|x| x["id"].as_str() == Some(id)) {
        // Preserve file / asset fields if the update omits them.
        let prev = &items[idx];
        for key in ["file", "asset_id", "half_extents", "data_url", "width", "height", "hex", "source"] {
            if stored.get(key).is_none() || stored[key].is_null() {
                if let Some(v) = prev.get(key) {
                    stored[key] = v.clone();
                }
            }
        }
        items[idx] = stored.clone();
    } else {
        items.push(stored.clone());
    }
    save_catalog(&dir, &catalog)?;
    Ok(json!({"item": stored, "items": catalog["items"]}))
}

pub fn remove(data_root: &Path, slug: Option<&str>, id: &str) -> Result<Value, String> {
    validate_id(id)?;
    if id == ROOT_ID {
        return Err("Cannot remove the root folder".into());
    }
    let dir = catalog_dir(data_root, slug)?;
    let root_name = resolve_root_name(data_root, slug);
    let mut catalog = load_catalog(&dir, &root_name)?;
    let items = catalog["items"].as_array().cloned().unwrap_or_default();
    let mut remove_ids = vec![id.to_string()];
    let mut grew = true;
    while grew {
        grew = false;
        for x in &items {
            let pid = x["parent"].as_str().unwrap_or("");
            let xid = x["id"].as_str().unwrap_or("");
            if remove_ids.iter().any(|r| r == pid) && !remove_ids.iter().any(|r| r == xid) {
                remove_ids.push(xid.to_string());
                grew = true;
            }
        }
    }
    let removed_files: Vec<String> = items
        .iter()
        .filter(|x| remove_ids.iter().any(|r| Some(r.as_str()) == x["id"].as_str()))
        .filter_map(|x| x["file"].as_str().map(str::to_owned))
        .collect();
    let next: Vec<Value> = items
        .into_iter()
        .filter(|x| !remove_ids.iter().any(|r| Some(r.as_str()) == x["id"].as_str()))
        .collect();
    catalog["items"] = json!(next);
    save_catalog(&dir, &catalog)?;
    for file in removed_files {
        let path = files_dir(&dir).join(&file);
        let _ = fs::remove_file(path);
    }
    Ok(json!({"removed": remove_ids, "items": catalog["items"]}))
}

pub fn handle(data_root: &Path, action: &str, body: &Value) -> Result<Option<Value>, String> {
    let slug = body["slug"].as_str().filter(|s| !s.is_empty());
    Ok(Some(match action {
        "project_resources" => list(data_root, slug)?,
        "project_resource_upsert" => upsert(data_root, slug, body)?,
        "project_resource_remove" => {
            let id = body["id"].as_str().ok_or("Missing id")?;
            remove(data_root, slug, id)?
        }
        "project_resource_store_file" => {
            let id = body["id"].as_str().ok_or("Missing id")?;
            let ext = body["ext"].as_str().ok_or("Missing ext")?;
            let b64 = body["data"].as_str().ok_or("Missing data")?;
            let bytes = base64_decode(b64)?;
            let file = store_file(data_root, slug, id, ext, &bytes)?;
            let absolute = file_path(data_root, slug, &file)?;
            json!({"file": file, "path": absolute.to_string_lossy()})
        }
        "project_resource_file_path" => {
            let file = body["file"].as_str().ok_or("Missing file")?;
            let absolute = file_path(data_root, slug, file)?;
            json!({"path": absolute.to_string_lossy()})
        }
        _ => return Ok(None),
    }))
}

fn base64_decode(input: &str) -> Result<Vec<u8>, String> {
    use std::collections::HashMap;
    // Prefer the same approach as elsewhere if available; keep a tiny local decoder
    // to avoid new deps. Engine already uses base64 via other crates — check.
    if let Ok(v) = general_purpose_decode(input) {
        return Ok(v);
    }
    let _ = HashMap::<u8, u8>::new();
    Err("Invalid base64".into())
}

fn general_purpose_decode(input: &str) -> Result<Vec<u8>, String> {
    // engine Cargo.toml likely has base64 — use std-friendly approach via serde or...
    #[allow(clippy::needless_return)]
    {
        // Manual decode using a simple alphabet table.
        const TABLE: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        let mut map = [255u8; 256];
        for (i, b) in TABLE.iter().enumerate() {
            map[*b as usize] = i as u8;
        }
        let clean: Vec<u8> = input
            .bytes()
            .filter(|b| !b.is_ascii_whitespace())
            .collect();
        if clean.len() % 4 != 0 {
            return Err("Invalid base64 length".into());
        }
        let mut out = Vec::with_capacity(clean.len() / 4 * 3);
        let mut i = 0;
        while i < clean.len() {
            let mut buf = [0u8; 4];
            let mut pad = 0;
            for j in 0..4 {
                let c = clean[i + j];
                if c == b'=' {
                    pad += 1;
                    buf[j] = 0;
                } else {
                    let v = map[c as usize];
                    if v == 255 {
                        return Err("Invalid base64".into());
                    }
                    buf[j] = v;
                }
            }
            out.push((buf[0] << 2) | (buf[1] >> 4));
            if pad < 2 {
                out.push((buf[1] << 4) | (buf[2] >> 2));
            }
            if pad < 1 {
                out.push((buf[2] << 6) | buf[3]);
            }
            i += 4;
        }
        Ok(out)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::projects::create;
    use std::env;

    fn temp_root() -> PathBuf {
        let mut path = env::temp_dir();
        path.push(format!(
            "tukurium-res-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_secs()
        ));
        let _ = fs::remove_dir_all(&path);
        fs::create_dir_all(&path).unwrap();
        path
    }

    #[test]
    fn workspace_and_project_catalog() {
        let root = temp_root();
        let listed = list(&root, None).unwrap();
        assert_eq!(listed["items"].as_array().unwrap().len(), 1);
        assert_eq!(listed["items"][0]["id"], ROOT_ID);

        create(
            &root,
            &json!({"slug":"cafe","display_name":"さくらカフェ"}),
        )
        .unwrap();
        let listed = list(&root, Some("cafe")).unwrap();
        assert_eq!(listed["root_name"], "さくらカフェ");

        let mat = upsert(
            &root,
            Some("cafe"),
            &json!({"item":{
                "id":"mat1","kind":"material","name":"桜色","parent":"r0",
                "hex":"#F7C7D9","is_new":true
            }}),
        )
        .unwrap();
        assert_eq!(mat["item"]["name"], "桜色");
        assert_eq!(list(&root, Some("cafe")).unwrap()["items"].as_array().unwrap().len(), 2);

        let file = store_file(&root, Some("cafe"), "tex1", "png", b"fakepng").unwrap();
        assert_eq!(file, "tex1.png");
        assert!(file_path(&root, Some("cafe"), &file).unwrap().is_file());

        remove(&root, Some("cafe"), "mat1").unwrap();
        assert_eq!(list(&root, Some("cafe")).unwrap()["items"].as_array().unwrap().len(), 1);
        let _ = fs::remove_dir_all(root);
    }
}
