//! Local project commits, branches, releases, and members under data_root/projects/<slug>/.
use crate::projects::{self, project_dir, validate_slug, world_path};
use kokoverse_core::replication::REGISTRY;
use kokoverse_core::WorldModel;
use kokoverse_protocol::Snapshot;
use serde_json::{json, Value};
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

fn now() -> String {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
        .to_string()
}

fn new_id() -> String {
    use std::sync::atomic::{AtomicU64, Ordering};
    static SEQ: AtomicU64 = AtomicU64::new(1);
    let n = SEQ.fetch_add(1, Ordering::Relaxed);
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    format!("{nanos}-{n:x}")
}

fn commits_dir(data_root: &Path, slug: &str) -> PathBuf {
    project_dir(data_root, slug).join("commits")
}

fn branches_path(data_root: &Path, slug: &str) -> PathBuf {
    project_dir(data_root, slug).join("branches.json")
}

fn releases_path(data_root: &Path, slug: &str) -> PathBuf {
    project_dir(data_root, slug).join("releases.json")
}

fn members_path(data_root: &Path, slug: &str) -> PathBuf {
    project_dir(data_root, slug).join("members.json")
}

fn head_path(data_root: &Path, slug: &str) -> PathBuf {
    project_dir(data_root, slug).join("HEAD")
}

fn ensure_vcs_layout(data_root: &Path, slug: &str) -> Result<(), String> {
    validate_slug(slug)?;
    let dir = project_dir(data_root, slug);
    if !dir.is_dir() {
        return Err("Project not found".into());
    }
    fs::create_dir_all(commits_dir(data_root, slug)).map_err(|e| e.to_string())?;
    if !branches_path(data_root, slug).is_file() {
        write_json(
            &branches_path(data_root, slug),
            &json!({"current":"main","branches":{"main":{"head":Value::Null}}}),
        )?;
    }
    if !releases_path(data_root, slug).is_file() {
        write_json(&releases_path(data_root, slug), &json!({"releases":[]}))?;
    }
    if !members_path(data_root, slug).is_file() {
        let host = placeholder_host(slug);
        write_json(
            &members_path(data_root, slug),
            &json!({
                "members": [{
                    "user_id": host,
                    "name": host,
                    "role": "host"
                }]
            }),
        )?;
    }
    if !head_path(data_root, slug).is_file() {
        fs::write(head_path(data_root, slug), "main").map_err(|e| e.to_string())?;
    }
    Ok(())
}

fn placeholder_host(slug: &str) -> String {
    format!("host@{slug}")
}

/// Resolve the caller's role for a project. Unknown users are treated as view.
pub fn role_of(data_root: &Path, slug: &str, user_id: &str) -> Result<String, String> {
    ensure_vcs_layout(data_root, slug)?;
    if user_id.is_empty() {
        return Ok("view".into());
    }
    let data = read_json(&members_path(data_root, slug))?;
    let members = data["members"].as_array().ok_or("Corrupt members.json")?;
    Ok(members
        .iter()
        .find(|m| m["user_id"].as_str() == Some(user_id))
        .and_then(|m| m["role"].as_str())
        .unwrap_or("view")
        .to_string())
}

pub fn require_host(data_root: &Path, slug: &str, actor_id: &str) -> Result<(), String> {
    if actor_id.is_empty() {
        return Err("Sign in before Host-only project actions".into());
    }
    if role_of(data_root, slug, actor_id)? != "host" {
        return Err("Only the project Host can do this".into());
    }
    Ok(())
}

fn actor_id(body: &Value) -> &str {
    body["actor_id"]
        .as_str()
        .or_else(|| body["user_id"].as_str())
        .unwrap_or("")
        .trim()
}

/// Bind the signed-in user as Host when members still use the placeholder host@slug.
pub fn bind_host(data_root: &Path, slug: &str, user_id: &str, name: &str) -> Result<(), String> {
    if user_id.is_empty() {
        return Ok(());
    }
    ensure_vcs_layout(data_root, slug)?;
    let mut data = read_json(&members_path(data_root, slug))?;
    let members = data["members"].as_array_mut().ok_or("Corrupt members.json")?;
    let placeholder = placeholder_host(slug);
    if let Some(host) = members.iter_mut().find(|m| m["role"].as_str() == Some("host")) {
        let current = host["user_id"].as_str().unwrap_or("");
        // Only claim Host while the placeholder remains; never steal from a real host.
        if current == placeholder || current == user_id {
            host["user_id"] = json!(user_id);
            host["name"] = json!(if name.is_empty() { user_id } else { name });
        }
    }
    write_json(&members_path(data_root, slug), &data)
}

const HOST_ACTIONS: &[&str] = &[
    "project_commit",
    "project_revert",
    "project_checkout",
    "project_branch_create",
    "project_branch_switch",
    "project_branch_merge_main",
    "project_release_create",
    "project_release_withdraw",
    "project_member_upsert",
];

fn write_json(path: &Path, value: &Value) -> Result<(), String> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(|e| e.to_string())?;
    }
    let tmp = path.with_extension("tmp");
    let bytes = serde_json::to_vec_pretty(value).map_err(|e| e.to_string())?;
    fs::write(&tmp, bytes).map_err(|e| e.to_string())?;
    fs::rename(tmp, path).map_err(|e| e.to_string())
}

fn read_json(path: &Path) -> Result<Value, String> {
    let bytes = fs::read(path).map_err(|e| e.to_string())?;
    serde_json::from_slice(&bytes).map_err(|e| e.to_string())
}

fn current_branch(data_root: &Path, slug: &str) -> Result<String, String> {
    ensure_vcs_layout(data_root, slug)?;
    let raw = fs::read_to_string(head_path(data_root, slug)).map_err(|e| e.to_string())?;
    Ok(raw.trim().to_string())
}

fn set_branch_head(data_root: &Path, slug: &str, branch: &str, commit_id: &str) -> Result<(), String> {
    let mut branches = read_json(&branches_path(data_root, slug))?;
    branches["branches"][branch]["head"] = json!(commit_id);
    branches["current"] = json!(branch);
    write_json(&branches_path(data_root, slug), &branches)?;
    fs::write(head_path(data_root, slug), branch).map_err(|e| e.to_string())
}

fn branch_head(data_root: &Path, slug: &str, branch: &str) -> Result<Option<String>, String> {
    let branches = read_json(&branches_path(data_root, slug))?;
    Ok(branches["branches"][branch]["head"]
        .as_str()
        .map(str::to_string))
}

fn world_bytes(data_root: &Path, slug: &str) -> Result<Vec<u8>, String> {
    fs::read(world_path(data_root, slug)).map_err(|e| e.to_string())
}

fn commit_path(data_root: &Path, slug: &str, id: &str) -> PathBuf {
    commits_dir(data_root, slug).join(format!("{id}.json"))
}

fn read_commit(data_root: &Path, slug: &str, id: &str) -> Result<Value, String> {
    read_json(&commit_path(data_root, slug, id))
}

fn list_commit_meta(data_root: &Path, slug: &str) -> Result<Vec<Value>, String> {
    ensure_vcs_layout(data_root, slug)?;
    let branch = current_branch(data_root, slug)?;
    let mut cursor = branch_head(data_root, slug, &branch)?;
    let mut out = Vec::new();
    let mut seen = std::collections::BTreeSet::new();
    while let Some(id) = cursor {
        if !seen.insert(id.clone()) {
            break;
        }
        let commit = read_commit(data_root, slug, &id)?;
        out.push(json!({
            "id": commit["id"],
            "message": commit["message"],
            "created_at": commit["created_at"],
            "parent": commit["parent"],
            "branch": branch,
        }));
        cursor = commit["parent"].as_str().map(str::to_string);
    }
    Ok(out)
}

fn snapshot_from_bytes(bytes: &[u8]) -> Result<Snapshot, String> {
    let stored: kokoverse_protocol::ReplicatedWorld =
        serde_json::from_slice(bytes).map_err(|e| e.to_string())?;
    REGISTRY.decode_world(stored)
}

fn address_set(snapshot: &Snapshot) -> std::collections::BTreeSet<String> {
    snapshot
        .objects
        .iter()
        .map(|o| o.address.instance_id.clone())
        .collect()
}

fn diff_snapshots(before: &Snapshot, after: &Snapshot) -> (Vec<Value>, Vec<String>) {
    let a = address_set(before);
    let b = address_set(after);
    let mut changes = Vec::new();
    let mut highlight = Vec::new();
    for id in b.difference(&a) {
        changes.push(json!({"kind":"added","address":id}));
        highlight.push(id.clone());
    }
    for id in a.difference(&b) {
        changes.push(json!({"kind":"removed","address":id}));
        highlight.push(id.clone());
    }
    for obj in &after.objects {
        let id = &obj.address.instance_id;
        if !a.contains(id) {
            continue;
        }
        if let Some(prev) = before.objects.iter().find(|o| o.address.instance_id == *id) {
            if prev.object_revision != obj.object_revision {
                changes.push(json!({"kind":"changed","address":id}));
                highlight.push(id.clone());
            }
        }
    }
    (changes, highlight)
}

pub fn working_status(data_root: &Path, slug: &str) -> Result<Value, String> {
    ensure_vcs_layout(data_root, slug)?;
    let branch = current_branch(data_root, slug)?;
    let head = branch_head(data_root, slug, &branch)?;
    let working = world_bytes(data_root, slug)?;
    let clean = match &head {
        Some(id) => {
            let commit = read_commit(data_root, slug, id)?;
            let stored = commit["world"].as_str().unwrap_or("").as_bytes();
            // world field stores raw JSON text of replicated world
            let commit_bytes = if commit["world_bytes"].is_string() {
                // fallback unused
                working.clone()
            } else {
                serde_json::to_vec(&commit["world"]).unwrap_or_default()
            };
            // Prefer dedicated blob file when present
            let blob = commits_dir(data_root, slug).join(format!("{id}.world.json"));
            if blob.is_file() {
                fs::read(&blob).unwrap_or_default() == working
            } else {
                let _ = stored;
                commit_bytes == working
            }
        }
        None => working.is_empty(),
    };
    Ok(json!({
        "slug": slug,
        "branch": branch,
        "head": head,
        "clean": clean,
    }))
}

pub fn commit(data_root: &Path, slug: &str, message: &str, author: &str) -> Result<Value, String> {
    ensure_vcs_layout(data_root, slug)?;
    let message = message.trim();
    if message.is_empty() {
        return Err("Commit message required".into());
    }
    let branch = current_branch(data_root, slug)?;
    let parent = branch_head(data_root, slug, &branch)?;
    let id = new_id();
    let working = world_bytes(data_root, slug)?;
    let world_value: Value = serde_json::from_slice(&working).map_err(|e| e.to_string())?;
    let meta = json!({
        "id": id,
        "message": message.chars().take(200).collect::<String>(),
        "created_at": now(),
        "author": author,
        "parent": parent,
        "branch": branch,
        "world": world_value,
    });
    write_json(&commit_path(data_root, slug, &id), &meta)?;
    let mut blob = fs::File::create(commits_dir(data_root, slug).join(format!("{id}.world.json")))
        .map_err(|e| e.to_string())?;
    blob.write_all(&working).map_err(|e| e.to_string())?;
    set_branch_head(data_root, slug, &branch, &id)?;
    projects::touch(data_root, slug)?;
    Ok(json!({
        "id": id,
        "message": message,
        "branch": branch,
        "created_at": meta["created_at"],
    }))
}

pub fn history(data_root: &Path, slug: &str) -> Result<Value, String> {
    let commits = list_commit_meta(data_root, slug)?;
    Ok(json!({
        "slug": slug,
        "branch": current_branch(data_root, slug)?,
        "commits": commits,
    }))
}

pub fn diff(data_root: &Path, slug: &str, commit_id: &str) -> Result<Value, String> {
    ensure_vcs_layout(data_root, slug)?;
    let commit = read_commit(data_root, slug, commit_id)?;
    let after_bytes = {
        let blob = commits_dir(data_root, slug).join(format!("{commit_id}.world.json"));
        if blob.is_file() {
            fs::read(blob).map_err(|e| e.to_string())?
        } else {
            serde_json::to_vec(&commit["world"]).map_err(|e| e.to_string())?
        }
    };
    let after = snapshot_from_bytes(&after_bytes)?;
    let before = if let Some(parent) = commit["parent"].as_str() {
        let blob = commits_dir(data_root, slug).join(format!("{parent}.world.json"));
        let bytes = if blob.is_file() {
            fs::read(blob).map_err(|e| e.to_string())?
        } else {
            let parent_commit = read_commit(data_root, slug, parent)?;
            serde_json::to_vec(&parent_commit["world"]).map_err(|e| e.to_string())?
        };
        snapshot_from_bytes(&bytes)?
    } else {
        Snapshot {
            world_revision: "0".into(),
            objects: vec![],
        }
    };
    let (changes, highlight_ids) = diff_snapshots(&before, &after);
    Ok(json!({
        "commit_id": commit_id,
        "changes": changes,
        "highlight_ids": highlight_ids,
    }))
}

pub fn checkout(data_root: &Path, slug: &str, commit_id: &str) -> Result<Value, String> {
    ensure_vcs_layout(data_root, slug)?;
    let blob = commits_dir(data_root, slug).join(format!("{commit_id}.world.json"));
    let bytes = if blob.is_file() {
        fs::read(blob).map_err(|e| e.to_string())?
    } else {
        let commit = read_commit(data_root, slug, commit_id)?;
        serde_json::to_vec(&commit["world"]).map_err(|e| e.to_string())?
    };
    let path = world_path(data_root, slug);
    let tmp = path.with_extension("json.tmp");
    fs::write(&tmp, &bytes).map_err(|e| e.to_string())?;
    fs::rename(tmp, path).map_err(|e| e.to_string())?;
    projects::touch(data_root, slug)?;
    Ok(json!({"slug": slug, "commit_id": commit_id, "restored": true}))
}

pub fn revert(data_root: &Path, slug: &str, commit_id: &str, author: &str) -> Result<Value, String> {
    // Soft revert: restore parent world into working tree, then commit as a new history entry.
    ensure_vcs_layout(data_root, slug)?;
    let entry = read_commit(data_root, slug, commit_id)?;
    let parent = entry["parent"].as_str().ok_or("Cannot revert the first commit")?;
    checkout(data_root, slug, parent)?;
    let message = format!("revert {}", commit_id);
    let created = commit(data_root, slug, &message, author)?;
    Ok(json!({
        "reverted": commit_id,
        "commit": created,
        "message": "revert を新しいコミットとして記録しました",
    }))
}

pub fn create_branch(data_root: &Path, slug: &str, name: &str) -> Result<Value, String> {
    ensure_vcs_layout(data_root, slug)?;
    let name = name.trim().to_lowercase();
    if name.is_empty() || name.len() > 40 {
        return Err("Invalid branch name".into());
    }
    let mut branches = read_json(&branches_path(data_root, slug))?;
    if branches["branches"].get(&name).is_some() {
        return Err("Branch already exists".into());
    }
    let current = current_branch(data_root, slug)?;
    let head = branch_head(data_root, slug, &current)?;
    branches["branches"][&name] = json!({"head": head});
    write_json(&branches_path(data_root, slug), &branches)?;
    Ok(json!({"branch": name, "head": head}))
}

pub fn switch_branch(data_root: &Path, slug: &str, name: &str) -> Result<Value, String> {
    ensure_vcs_layout(data_root, slug)?;
    let branches = read_json(&branches_path(data_root, slug))?;
    if branches["branches"].get(name).is_none() {
        return Err("Branch not found".into());
    }
    fs::write(head_path(data_root, slug), name).map_err(|e| e.to_string())?;
    let mut branches = branches;
    branches["current"] = json!(name);
    write_json(&branches_path(data_root, slug), &branches)?;
    if let Some(head) = branch_head(data_root, slug, name)? {
        checkout(data_root, slug, &head)?;
    }
    Ok(json!({"branch": name}))
}

pub fn merge_to_main(data_root: &Path, slug: &str) -> Result<Value, String> {
    ensure_vcs_layout(data_root, slug)?;
    let current = current_branch(data_root, slug)?;
    if current == "main" {
        return Err("Already on main".into());
    }
    let head = branch_head(data_root, slug, &current)?.ok_or("Branch has no commits")?;
    let main_head = branch_head(data_root, slug, "main")?;
    // Fast-forward only when main is an ancestor of current (simplified: main head is parent chain).
    if let Some(main_id) = main_head {
        let mut cursor = Some(head.clone());
        let mut found = false;
        let mut guard = 0;
        while let Some(id) = cursor {
            guard += 1;
            if guard > 500 {
                break;
            }
            if id == main_id {
                found = true;
                break;
            }
            cursor = read_commit(data_root, slug, &id)?["parent"]
                .as_str()
                .map(str::to_string);
        }
        if !found {
            return Err("Merge conflict: only fast-forward merges are supported".into());
        }
    }
    set_branch_head(data_root, slug, "main", &head)?;
    fs::write(head_path(data_root, slug), "main").map_err(|e| e.to_string())?;
    let mut branches = read_json(&branches_path(data_root, slug))?;
    branches["current"] = json!("main");
    write_json(&branches_path(data_root, slug), &branches)?;
    checkout(data_root, slug, &head)?;
    Ok(json!({"merged": current, "main_head": head}))
}

pub fn list_releases(data_root: &Path, slug: &str) -> Result<Value, String> {
    ensure_vcs_layout(data_root, slug)?;
    let data = read_json(&releases_path(data_root, slug))?;
    Ok(json!({"slug": slug, "releases": data["releases"], "visibility": "private"}))
}

pub fn create_release(data_root: &Path, slug: &str) -> Result<Value, String> {
    ensure_vcs_layout(data_root, slug)?;
    let branch = current_branch(data_root, slug)?;
    let head = branch_head(data_root, slug, &branch)?.ok_or("Commit before creating a release")?;
    let mut data = read_json(&releases_path(data_root, slug))?;
    let releases = data["releases"].as_array_mut().ok_or("Corrupt releases.json")?;
    for entry in releases.iter_mut() {
        entry["latest"] = json!(false);
    }
    let id = new_id();
    let tag = format!("r{}", releases.len() + 1);
    let entry = json!({
        "id": id,
        "tag": tag,
        "commit_id": head,
        "created_at": now(),
        "latest": true,
        "withdrawn": false,
        "workshop": "private",
    });
    releases.insert(0, entry.clone());
    write_json(&releases_path(data_root, slug), &data)?;
    Ok(entry)
}

pub fn withdraw_release(data_root: &Path, slug: &str, id: &str) -> Result<Value, String> {
    ensure_vcs_layout(data_root, slug)?;
    let mut data = read_json(&releases_path(data_root, slug))?;
    let releases = data["releases"].as_array_mut().ok_or("Corrupt releases.json")?;
    let mut found = false;
    for entry in releases.iter_mut() {
        if entry["id"].as_str() == Some(id) {
            entry["withdrawn"] = json!(true);
            entry["latest"] = json!(false);
            found = true;
        }
    }
    if !found {
        return Err("Release not found".into());
    }
    write_json(&releases_path(data_root, slug), &data)?;
    Ok(json!({"id": id, "withdrawn": true}))
}

pub fn list_members(data_root: &Path, slug: &str) -> Result<Value, String> {
    ensure_vcs_layout(data_root, slug)?;
    let data = read_json(&members_path(data_root, slug))?;
    Ok(json!({"slug": slug, "members": data["members"]}))
}

pub fn upsert_member(data_root: &Path, slug: &str, user_id: &str, role: &str, name: &str) -> Result<Value, String> {
    ensure_vcs_layout(data_root, slug)?;
    let role = match role {
        "host" | "edit" | "view" => role,
        _ => return Err("Role must be host, edit, or view".into()),
    };
    if role == "host" {
        return Err("Host is fixed to the workspace creator".into());
    }
    let user_id = user_id.trim();
    if user_id.is_empty() {
        return Err("user_id required".into());
    }
    let mut data = read_json(&members_path(data_root, slug))?;
    let members = data["members"].as_array_mut().ok_or("Corrupt members.json")?;
    if let Some(existing) = members.iter_mut().find(|m| m["user_id"].as_str() == Some(user_id)) {
        existing["role"] = json!(role);
        if !name.is_empty() {
            existing["name"] = json!(name);
        }
    } else {
        members.push(json!({
            "user_id": user_id,
            "name": if name.is_empty() { user_id } else { name },
            "role": role,
        }));
    }
    write_json(&members_path(data_root, slug), &data)?;
    Ok(json!({"user_id": user_id, "role": role}))
}

/// Optional live world snapshot for commit-from-session (when Engine holds active_project).
#[allow(dead_code)]
pub fn commit_snapshot(
    data_root: &Path,
    slug: &str,
    message: &str,
    author: &str,
    snapshot: &Snapshot,
) -> Result<Value, String> {
    projects::save_world(data_root, slug, snapshot)?;
    commit(data_root, slug, message, author)
}

#[allow(dead_code)]
pub fn validate_model_loads(data_root: &Path, slug: &str) -> Result<(), String> {
    let bytes = world_bytes(data_root, slug)?;
    let _ = WorldModel::new();
    let _ = snapshot_from_bytes(&bytes)?;
    Ok(())
}

pub fn handle(data_root: &Path, action: &str, body: &Value) -> Result<Option<Value>, String> {
    let slug = body["slug"].as_str().unwrap_or("").trim();
    if slug.is_empty() && action.starts_with("project_") {
        return Ok(None);
    }
    if !slug.is_empty() && HOST_ACTIONS.contains(&action) {
        require_host(data_root, slug, actor_id(body))?;
    }
    let actor = actor_id(body);
    Ok(Some(match action {
        "project_working_status" => {
            validate_slug(slug)?;
            let mut status = working_status(data_root, slug)?;
            status["my_role"] = json!(role_of(data_root, slug, actor)?);
            status
        }
        "project_commit" => {
            validate_slug(slug)?;
            let message = body["message"].as_str().unwrap_or("");
            let author = body["author"]
                .as_str()
                .filter(|s| !s.is_empty())
                .unwrap_or(actor);
            let created = commit(data_root, slug, message, author)?;
            json!({
                "id": created["id"],
                "message": created.get("message").cloned().unwrap_or(json!(message)),
                "branch": created.get("branch").cloned().unwrap_or(json!("main")),
                "created_at": created.get("created_at").cloned().unwrap_or(json!("")),
                "ok_message": "コミットしました",
            })
        }
        "project_history" => {
            validate_slug(slug)?;
            let mut hist = history(data_root, slug)?;
            hist["my_role"] = json!(role_of(data_root, slug, actor)?);
            hist
        }
        "project_diff" => {
            validate_slug(slug)?;
            let commit_id = body["commit_id"].as_str().ok_or("Missing commit_id")?;
            diff(data_root, slug, commit_id)?
        }
        "project_checkout" => {
            validate_slug(slug)?;
            let commit_id = body["commit_id"].as_str().ok_or("Missing commit_id")?;
            checkout(data_root, slug, commit_id)?
        }
        "project_revert" => {
            validate_slug(slug)?;
            let commit_id = body["commit_id"].as_str().ok_or("Missing commit_id")?;
            let author = body["author"]
                .as_str()
                .filter(|s| !s.is_empty())
                .unwrap_or(actor);
            revert(data_root, slug, commit_id, author)?
        }
        "project_branch_create" => {
            validate_slug(slug)?;
            let name = body["name"].as_str().unwrap_or("");
            create_branch(data_root, slug, name)?
        }
        "project_branch_switch" => {
            validate_slug(slug)?;
            let name = body["name"].as_str().ok_or("Missing branch name")?;
            switch_branch(data_root, slug, name)?
        }
        "project_branch_merge_main" => {
            validate_slug(slug)?;
            merge_to_main(data_root, slug)?
        }
        "project_releases" => {
            validate_slug(slug)?;
            list_releases(data_root, slug)?
        }
        "project_release_create" => {
            validate_slug(slug)?;
            create_release(data_root, slug)?
        }
        "project_release_withdraw" => {
            validate_slug(slug)?;
            let id = body["id"].as_str().ok_or("Missing release id")?;
            withdraw_release(data_root, slug, id)?
        }
        "project_members" => {
            validate_slug(slug)?;
            let mut listed = list_members(data_root, slug)?;
            listed["my_role"] = json!(role_of(data_root, slug, actor)?);
            listed
        }
        "project_member_upsert" => {
            validate_slug(slug)?;
            let user_id = body["user_id"].as_str().unwrap_or("");
            let role = body["role"].as_str().unwrap_or("edit");
            let name = body["name"].as_str().unwrap_or(user_id);
            upsert_member(data_root, slug, user_id, role, name)?
        }
        _ => return Ok(None),
    }))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::projects;
    use std::env;

    fn temp_root() -> PathBuf {
        use std::sync::atomic::{AtomicU64, Ordering};
        static SEQ: AtomicU64 = AtomicU64::new(1);
        let mut path = env::temp_dir();
        path.push(format!(
            "tukurium-vcs-{}-{}-{}",
            std::process::id(),
            now(),
            SEQ.fetch_add(1, Ordering::Relaxed)
        ));
        let _ = fs::remove_dir_all(&path);
        fs::create_dir_all(&path).unwrap();
        path
    }

    fn empty_replicated_bytes() -> Vec<u8> {
        let snapshot = WorldModel::new().snapshot();
        // Flip revision so the blob differs from the initial project world.
        let mut snap = snapshot;
        snap.world_revision = "dirty".into();
        serde_json::to_vec(&REGISTRY.encode_world(&snap)).unwrap()
    }

    #[test]
    fn commit_history_diff_and_release() {
        let root = temp_root();
        let created = projects::create(
            &root,
            &json!({"slug":"cafe","display_name":"Cafe","actor_id":"u-host","actor_name":"Host"}),
        )
        .unwrap();
        assert_eq!(created["slug"], "cafe");
        assert_eq!(created["my_role"], "host");
        let c1 = commit(&root, "cafe", "first", "u-host").unwrap();
        let status = working_status(&root, "cafe").unwrap();
        assert_eq!(status["clean"], true);
        // dirty working tree: rewrite with a distinct empty replicated world blob
        let dirty = empty_replicated_bytes();
        fs::write(world_path(&root, "cafe"), &dirty).unwrap();
        let c2 = commit(&root, "cafe", "second", "u-host").unwrap();
        assert_ne!(c1["id"], c2["id"]);
        let hist = history(&root, "cafe").unwrap();
        assert_eq!(hist["commits"].as_array().unwrap().len(), 2);
        let d = diff(&root, "cafe", c2["id"].as_str().unwrap()).unwrap();
        assert!(d["changes"].as_array().is_some());
        let release = create_release(&root, "cafe").unwrap();
        assert_eq!(release["latest"], true);
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn host_only_actions_reject_edit_role() {
        let root = temp_root();
        projects::create(
            &root,
            &json!({"slug":"lab","display_name":"Lab","actor_id":"owner","actor_name":"Owner"}),
        )
        .unwrap();
        upsert_member(&root, "lab", "editor", "edit", "Editor").unwrap();
        let denied = handle(
            &root,
            "project_commit",
            &json!({"slug":"lab","message":"nope","actor_id":"editor"}),
        );
        assert!(denied.unwrap_err().contains("Host"));
        let allowed = handle(
            &root,
            "project_commit",
            &json!({"slug":"lab","message":"ok","actor_id":"owner","author":"Owner"}),
        )
        .unwrap()
        .unwrap();
        assert!(allowed["id"].as_str().is_some());
        let history_ok = handle(
            &root,
            "project_history",
            &json!({"slug":"lab","actor_id":"editor"}),
        )
        .unwrap()
        .unwrap();
        assert_eq!(history_ok["my_role"], "edit");
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn commit_snapshot_writes_working_tree_then_commits() {
        let root = temp_root();
        projects::create(
            &root,
            &json!({"slug":"snap","actor_id":"owner","actor_name":"Owner"}),
        )
        .unwrap();
        let model = WorldModel::new();
        let mut snapshot = model.snapshot();
        snapshot.world_revision = "live-1".into();
        let created =
            commit_snapshot(&root, "snap", "from live", "owner", &snapshot).unwrap();
        assert!(created["id"].as_str().is_some());
        let status = working_status(&root, "snap").unwrap();
        assert_eq!(status["clean"], true);
        let _ = fs::remove_dir_all(root);
    }
}
