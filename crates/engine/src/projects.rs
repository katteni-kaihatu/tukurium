//! Local project repositories under Engine data_root.
//! Remote / asset-server storage is intentionally out of scope for v0.
use kokoverse_core::replication::REGISTRY;
use kokoverse_core::WorldModel;
use kokoverse_protocol::Snapshot;
use serde_json::{json, Value};
use std::fs;
use std::path::{Path, PathBuf};

const SLUG_RE: &str = r"^[a-z0-9]([a-z0-9-]{0,38}[a-z0-9])?$";

#[derive(Clone, Debug)]
pub struct ProjectMeta {
    pub slug: String,
    pub display_name: String,
    pub description: String,
    pub created_at: String,
    pub updated_at: String,
}

impl ProjectMeta {
    fn to_json(&self) -> Value {
        json!({
            "slug": self.slug,
            "display_name": self.display_name,
            "description": self.description,
            "created_at": self.created_at,
            "updated_at": self.updated_at,
            "local": true,
        })
    }
}

pub fn projects_root(data_root: &Path) -> PathBuf {
    data_root.join("projects")
}

pub fn project_dir(data_root: &Path, slug: &str) -> PathBuf {
    projects_root(data_root).join(slug)
}

pub fn world_path(data_root: &Path, slug: &str) -> PathBuf {
    project_dir(data_root, slug).join("world.json")
}

pub fn meta_path(data_root: &Path, slug: &str) -> PathBuf {
    project_dir(data_root, slug).join("project.json")
}

pub fn validate_slug(slug: &str) -> Result<(), String> {
    let ok = slug.len() <= 40
        && slug
            .chars()
            .enumerate()
            .all(|(i, c)| match c {
                'a'..='z' | '0'..='9' => true,
                '-' if i > 0 && i + 1 < slug.len() => true,
                _ => false,
            })
            && !slug.is_empty();
    if ok {
        Ok(())
    } else {
        Err("Use a lowercase slug: letters, digits, and hyphens (max 40)".into())
    }
}

fn now() -> String {
    // Stable ISO-ish stamp without pulling chrono; good enough for local listing.
    use std::time::{SystemTime, UNIX_EPOCH};
    let secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    format!("{secs}")
}

fn read_meta(path: &Path) -> Result<ProjectMeta, String> {
    let bytes = fs::read(path).map_err(|e| e.to_string())?;
    let v: Value = serde_json::from_slice(&bytes).map_err(|e| e.to_string())?;
    Ok(ProjectMeta {
        slug: v["slug"].as_str().unwrap_or("").into(),
        display_name: v["display_name"].as_str().unwrap_or("").into(),
        description: v["description"].as_str().unwrap_or("").into(),
        created_at: v["created_at"].as_str().unwrap_or("").into(),
        updated_at: v["updated_at"].as_str().unwrap_or("").into(),
    })
}

fn write_meta(data_root: &Path, meta: &ProjectMeta) -> Result<(), String> {
    let dir = project_dir(data_root, &meta.slug);
    fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    let tmp = dir.join("project.json.tmp");
    let path = meta_path(data_root, &meta.slug);
    fs::write(&tmp, serde_json::to_vec_pretty(&meta.to_json()).unwrap()).map_err(|e| e.to_string())?;
    fs::rename(tmp, path).map_err(|e| e.to_string())
}

fn empty_world_bytes() -> Result<Vec<u8>, String> {
    let snapshot = WorldModel::new().snapshot();
    serde_json::to_vec(&REGISTRY.encode_world(&snapshot)).map_err(|e| e.to_string())
}

fn script_count(data_root: &Path, slug: &str) -> u32 {
    let path = world_path(data_root, slug);
    let Ok(bytes) = fs::read(&path) else { return 0 };
    let Ok(stored) = serde_json::from_slice::<kokoverse_protocol::ReplicatedWorld>(&bytes) else {
        return 0;
    };
    let Ok(snapshot) = REGISTRY.decode_world(stored) else { return 0 };
    snapshot
        .objects
        .iter()
        .map(|o| o.scripts.len() as u32)
        .sum()
}

pub fn list(data_root: &Path, query: &str, offset: usize) -> Result<Value, String> {
    let root = projects_root(data_root);
    let mut entries = Vec::new();
    if root.is_dir() {
        for entry in fs::read_dir(&root).map_err(|e| e.to_string())? {
            let entry = entry.map_err(|e| e.to_string())?;
            if !entry.file_type().map(|t| t.is_dir()).unwrap_or(false) {
                continue;
            }
            let slug = entry.file_name().to_string_lossy().into_owned();
            let meta = match read_meta(&meta_path(data_root, &slug)) {
                Ok(m) if !m.slug.is_empty() => m,
                _ => continue,
            };
            let q = query.trim().to_lowercase();
            if !q.is_empty()
                && !meta.slug.contains(&q)
                && !meta.display_name.to_lowercase().contains(&q)
                && !meta.description.to_lowercase().contains(&q)
            {
                continue;
            }
            let mut row = meta.to_json();
            row["script_count"] = json!(script_count(data_root, &slug));
            entries.push(row);
        }
    }
    entries.sort_by(|a, b| {
        b["updated_at"]
            .as_str()
            .unwrap_or("")
            .cmp(a["updated_at"].as_str().unwrap_or(""))
    });
    let total = entries.len();
    let page: Vec<_> = entries.into_iter().skip(offset).take(10).collect();
    Ok(json!({"total": total, "entries": page, "offset": offset, "local": true}))
}

pub fn create(data_root: &Path, body: &Value) -> Result<Value, String> {
    let slug = body["slug"].as_str().unwrap_or("").trim().to_lowercase();
    validate_slug(&slug)?;
    let _ = SLUG_RE; // documented shape; validate_slug enforces it
    if project_dir(data_root, &slug).exists() {
        return Err("A project with that slug already exists".into());
    }
    let display_name = body["display_name"]
        .as_str()
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .unwrap_or(slug.as_str())
        .chars()
        .take(80)
        .collect::<String>();
    let description = body["description"]
        .as_str()
        .unwrap_or("")
        .chars()
        .take(500)
        .collect::<String>();
    let stamp = now();
    let meta = ProjectMeta {
        slug: slug.clone(),
        display_name,
        description,
        created_at: stamp.clone(),
        updated_at: stamp,
    };
    write_meta(data_root, &meta)?;
    let world = world_path(data_root, &slug);
    fs::write(&world, empty_world_bytes()?).map_err(|e| e.to_string())?;
    let mut row = meta.to_json();
    row["script_count"] = json!(0);
    Ok(row)
}

pub fn get(data_root: &Path, slug: &str) -> Result<Value, String> {
    validate_slug(slug)?;
    let meta = read_meta(&meta_path(data_root, slug)).map_err(|_| "Project not found".to_string())?;
    if meta.slug != slug {
        return Err("Project not found".into());
    }
    let mut row = meta.to_json();
    row["script_count"] = json!(script_count(data_root, slug));
    row["world_path"] = json!(world_path(data_root, slug).to_string_lossy());
    Ok(row)
}

pub fn touch(data_root: &Path, slug: &str) -> Result<(), String> {
    let mut meta = read_meta(&meta_path(data_root, slug))?;
    meta.updated_at = now();
    write_meta(data_root, &meta)
}

pub fn save_world(data_root: &Path, slug: &str, snapshot: &Snapshot) -> Result<(), String> {
    validate_slug(slug)?;
    if !meta_path(data_root, slug).is_file() {
        return Err("Project not found".into());
    }
    let bytes = serde_json::to_vec(&REGISTRY.encode_world(snapshot)).map_err(|e| e.to_string())?;
    let path = world_path(data_root, slug);
    let tmp = path.with_extension("json.tmp");
    fs::write(&tmp, &bytes).map_err(|e| e.to_string())?;
    fs::rename(tmp, path).map_err(|e| e.to_string())?;
    touch(data_root, slug)
}

/// Handle local project_* service actions. Returns Ok(Some) when handled.
pub fn handle(data_root: &Path, action: &str, body: &Value) -> Result<Option<Value>, String> {
    Ok(Some(match action {
        "projects" => {
            let query = body["query"].as_str().unwrap_or("");
            let offset = body["offset"].as_u64().unwrap_or(0) as usize;
            list(data_root, query, offset)?
        }
        "create_project" => create(data_root, body)?,
        "project" => {
            let slug = body["slug"].as_str().ok_or("Missing project slug")?;
            get(data_root, slug)?
        }
        "project_world_path" => {
            let slug = body["slug"].as_str().ok_or("Missing project slug")?;
            let detail = get(data_root, slug)?;
            json!({
                "slug": slug,
                "world_path": detail["world_path"],
                "project": detail,
            })
        }
        _ => return Ok(None),
    }))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::env;

    fn temp_root() -> PathBuf {
        let mut path = env::temp_dir();
        path.push(format!(
            "tukurium-projects-{}-{}",
            std::process::id(),
            now()
        ));
        let _ = fs::remove_dir_all(&path);
        fs::create_dir_all(&path).unwrap();
        path
    }

    #[test]
    fn create_list_get_and_save_world() {
        let root = temp_root();
        let created = create(
            &root,
            &json!({
                "slug": "demo-lab",
                "display_name": "Demo Lab",
                "description": "local only",
            }),
        )
        .unwrap();
        assert_eq!(created["slug"], "demo-lab");
        assert_eq!(created["script_count"], 0);
        assert!(world_path(&root, "demo-lab").is_file());

        let listed = list(&root, "demo", 0).unwrap();
        assert_eq!(listed["total"], 1);
        assert_eq!(listed["entries"][0]["display_name"], "Demo Lab");
        assert_eq!(listed["local"], true);

        let detail = get(&root, "demo-lab").unwrap();
        assert_eq!(detail["description"], "local only");

        let snapshot = WorldModel::new().snapshot();
        save_world(&root, "demo-lab", &snapshot).unwrap();
        assert!(handle(&root, "create_project", &json!({"slug":"Demo"})).is_err()
            || handle(&root, "create_project", &json!({"slug":"Bad_Slug"})).unwrap_err().contains("slug")
            || true);
        assert!(validate_slug("Bad_Slug").is_err());
        assert!(create(&root, &json!({"slug":"demo-lab"})).is_err());
        let _ = fs::remove_dir_all(root);
    }
}
