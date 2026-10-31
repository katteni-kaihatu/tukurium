use base64::Engine as _;
use kokoverse_asset_server::{Client, Profile};
use serde_json::{Value, json};
use std::{
    path::{Path, PathBuf},
    sync::Arc,
};
use tokio::sync::Mutex;

#[derive(Clone)]
pub struct Service {
    pub profile: Arc<Mutex<Profile>>,
    pub profile_path: PathBuf,
    pub data_root: PathBuf,
    pub asset_root: PathBuf,
}
pub struct Completion {
    pub response: Value,
    pub effect: Effect,
}
pub enum Effect {
    None,
    Login(Value),
    Join(Value),
    Leave,
    Place(Value),
    Verify {
        peer: String,
        epoch: String,
        user: Value,
    },
}

impl Service {
    pub fn open(
        server: String,
        profile_path: PathBuf,
        data_root: PathBuf,
        asset_root: PathBuf,
    ) -> Result<Self, String> {
        let profile = if profile_path.exists() {
            let b = std::fs::read(&profile_path).map_err(|e| e.to_string())?;
            let b = unprotect(&b)?;
            let p: Profile = serde_json::from_slice(&b).map_err(|e| e.to_string())?;
            if p.server != server {
                return Err(
                    "Profile belongs to a different server; use another profile directory".into(),
                );
            }
            p
        } else {
            Profile {
                server,
                token: kokoverse_asset_server::secret(),
                user: Value::Null,
            }
        };
        save_profile(&profile_path, &profile)?;
        Ok(Self {
            profile: Arc::new(Mutex::new(profile)),
            profile_path,
            data_root,
            asset_root,
        })
    }
    pub async fn client(&self) -> Result<Client, String> {
        let p = self.profile.lock().await;
        Client::new(p.server.clone(), p.token.clone())
    }
    pub async fn execute(&self, mut body: Value) -> Result<Completion, String> {
        let action = body["action"].as_str().unwrap_or("").to_string();
        if action == "login" {
            let mut p = self.profile.lock().await;
            let c = Client::new(p.server.clone(), p.token.clone())?;
            let name = body["name"].as_str().ok_or("Enter your name")?;
            let mut u = c.register(name).await?;
            p.token = u
                .as_object_mut()
                .and_then(|u| u.remove("token"))
                .and_then(|v| v.as_str().map(str::to_owned))
                .ok_or("Missing HN session token")?;
            p.user = u;
            save_profile(&self.profile_path, &p)?;
            return Ok(Completion {
                response: p.user.clone(),
                effect: Effect::Login(p.user.clone()),
            });
        }
        if action == "import_profile" {
            let path = PathBuf::from(body["path"].as_str().ok_or("Choose a profile file")?);
            let imported: Profile =
                serde_json::from_slice(&std::fs::read(path).map_err(|e| e.to_string())?)
                    .map_err(|_| "Invalid profile file")?;
            let mut p = self.profile.lock().await;
            if p.server != imported.server {
                return Err("The profile uses a different server".into());
            }
            let client = Client::new(imported.server.clone(), imported.token.clone())?;
            let u = client.rpc(json!({"action":"me"})).await?;
            *p = Profile {
                user: u.clone(),
                ..imported
            };
            save_profile(&self.profile_path, &p)?;
            return Ok(Completion {
                response: u.clone(),
                effect: Effect::Login(u),
            });
        }
        let client = self.client().await?;
        if action == "export_profile" {
            let path = PathBuf::from(body["path"].as_str().ok_or("Choose a destination")?);
            if path.exists() {
                return Err("Choose a new file; existing files are not replaced".into());
            }
            let p = self.profile.lock().await;
            std::fs::write(path, serde_json::to_vec_pretty(&*p).unwrap())
                .map_err(|e| e.to_string())?;
            return Ok(Completion {
                response: json!({"exported":true}),
                effect: Effect::None,
            });
        }
        if action == "save_item" {
            let object = &body["object"];
            // Shared items may reference an asset already stored by another user.
            // Upload local imports; the service validates existing remote references.
            if let Some(id) = object["visual"]["asset_id"].as_str()
                && let Ok(path) = find_asset(&self.asset_root, id)
            {
                let bytes = tokio::fs::read(path).await.map_err(|e| e.to_string())?;
                client.upload(id, bytes).await?;
            }
        }
        if action == "resolve_placement" {
            let p = client.rpc(body).await?;
            if let Some(id) = p["object"]["visual"]["asset_id"].as_str()
                && find_asset(&self.asset_root, id).is_err()
            {
                let bytes = client.download(id).await?;
                self.store_asset(id, &bytes)?;
            }
            return Ok(Completion {
                response: json!({"placed":true}),
                effect: Effect::Place(p),
            });
        }
        if action == "verify_ticket" {
            let peer = body["peer"].as_str().unwrap_or("").to_string();
            let epoch = body["peer_epoch"].as_str().unwrap_or("").to_string();
            body.as_object_mut().unwrap().remove("peer_epoch");
            let u = client.rpc(body).await?;
            return Ok(Completion {
                response: json!({"verified":true}),
                effect: Effect::Verify {
                    peer,
                    epoch,
                    user: u,
                },
            });
        }
        if action == "leave_session" {
            return Ok(Completion {
                response: json!({"left":true}),
                effect: Effect::Leave,
            });
        }
        if let Some(local) = crate::projects::handle(&self.data_root, &action, &body)? {
            return Ok(Completion {
                response: local,
                effect: Effect::None,
            });
        }
        if action == "open_project_workspace" {
            let slug = body["slug"].as_str().ok_or("Missing project slug")?.to_string();
            let detail = crate::projects::get(&self.data_root, &slug)?;
            let world = crate::projects::world_path(&self.data_root, &slug);
            if !world.is_file() {
                return Err("Project world is missing".into());
            }
            let name = detail["display_name"].as_str().unwrap_or(&slug);
            let mut v = client
                .rpc(json!({"action":"create_session","name": format!("project:{name}")}))
                .await?;
            v["load_world"] = json!(world.to_string_lossy());
            v["project_slug"] = json!(slug);
            return Ok(Completion {
                response: v.clone(),
                effect: Effect::Join(v),
            });
        }
        let load_world = body.as_object_mut().and_then(|o| o.remove("load_world"));
        let mut v = client.rpc(body).await?;
        if action == "create_session"
            && let Some(path) = load_world
        {
            v["load_world"] = path;
        }
        let effect = match action.as_str() {
            "create_session" | "join_session" => Effect::Join(v.clone()),
            _ => Effect::None,
        };
        Ok(Completion {
            response: v,
            effect,
        })
    }
    fn store_asset(&self, id: &str, bytes: &[u8]) -> Result<(), String> {
        if !kokoverse_protocol::valid_asset_id(id) || kokoverse_asset_server::hash(bytes) != id {
            return Err("Invalid asset".into());
        }
        let ext = if bytes.starts_with(b"glTF") {
            "glb"
        } else if bytes.starts_with(b"OggS") {
            "ogv"
        } else {
            "png"
        };
        std::fs::create_dir_all(&self.asset_root).map_err(|e| e.to_string())?;
        std::fs::write(self.asset_root.join(format!("{id}.{ext}")), bytes)
            .map_err(|e| e.to_string())
    }
}
fn find_asset(root: &Path, id: &str) -> Result<PathBuf, String> {
    if !kokoverse_protocol::valid_asset_id(id) {
        return Err("Invalid asset ID".into());
    }
    for ext in ["glb", "ogv", "png"] {
        let p = root.join(format!("{id}.{ext}"));
        if p.is_file() {
            return Ok(p);
        }
    }
    Err("Asset is not yet available locally; wait for the transfer".into())
}
fn save_profile(path: &Path, p: &Profile) -> Result<(), String> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(|e| e.to_string())?;
    }
    let data = protect(&serde_json::to_vec(p).unwrap())?;
    let tmp = path.with_extension("tmp");
    std::fs::write(&tmp, data).map_err(|e| e.to_string())?;
    std::fs::rename(tmp, path).map_err(|e| e.to_string())
}

#[cfg(windows)]
#[repr(C)]
struct Blob {
    len: u32,
    data: *mut u8,
}
#[cfg(windows)]
fn crypt(bytes: &[u8], encrypt: bool) -> Result<Vec<u8>, String> {
    #[link(name = "crypt32")]
    unsafe extern "system" {
        fn CryptProtectData(
            a: *const Blob,
            b: *const u16,
            c: *const Blob,
            d: *mut std::ffi::c_void,
            e: *mut std::ffi::c_void,
            f: u32,
            g: *mut Blob,
        ) -> i32;
        fn CryptUnprotectData(
            a: *const Blob,
            b: *mut *mut u16,
            c: *const Blob,
            d: *mut std::ffi::c_void,
            e: *mut std::ffi::c_void,
            f: u32,
            g: *mut Blob,
        ) -> i32;
    }
    #[link(name = "kernel32")]
    unsafe extern "system" {
        fn LocalFree(p: *mut std::ffi::c_void) -> *mut std::ffi::c_void;
    }
    let input = Blob {
        len: bytes.len() as u32,
        data: bytes.as_ptr() as *mut u8,
    };
    let mut output = Blob {
        len: 0,
        data: std::ptr::null_mut(),
    };
    // DPAPI owns output; copy it before releasing the OS allocation.
    unsafe {
        let ok = if encrypt {
            CryptProtectData(
                &input,
                std::ptr::null(),
                std::ptr::null(),
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                1,
                &mut output,
            )
        } else {
            CryptUnprotectData(
                &input,
                std::ptr::null_mut(),
                std::ptr::null(),
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                1,
                &mut output,
            )
        };
        if ok == 0 {
            return Err("Could not protect/read the local user profile".into());
        }
        let data = std::slice::from_raw_parts(output.data, output.len as usize).to_vec();
        LocalFree(output.data.cast());
        Ok(data)
    }
}
fn protect(bytes: &[u8]) -> Result<Vec<u8>, String> {
    #[cfg(windows)]
    {
        Ok(format!(
            "dpapi:{}",
            base64::engine::general_purpose::STANDARD.encode(crypt(bytes, true)?)
        )
        .into_bytes())
    }
    #[cfg(not(windows))]
    {
        Ok(bytes.to_vec())
    }
}
fn unprotect(bytes: &[u8]) -> Result<Vec<u8>, String> {
    #[cfg(windows)]
    {
        let text = std::str::from_utf8(bytes).map_err(|_| "Invalid profile")?;
        let bytes = base64::engine::general_purpose::STANDARD
            .decode(
                text.strip_prefix("dpapi:")
                    .ok_or("Invalid protected profile")?,
            )
            .map_err(|_| "Invalid profile")?;
        crypt(&bytes, false)
    }
    #[cfg(not(windows))]
    {
        Ok(bytes.to_vec())
    }
}
