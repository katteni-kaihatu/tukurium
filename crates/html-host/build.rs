use std::path::PathBuf;

fn main() {
    if std::env::var("CARGO_CFG_TARGET_OS").ok().as_deref() != Some("windows") {
        return;
    }
    let arch = match std::env::var("CARGO_CFG_TARGET_ARCH").unwrap_or_default().as_str() {
        "x86_64" => "x64",
        "aarch64" => "arm64",
        "x86" => "x86",
        other => {
            println!("cargo:warning=html-host: no WebView2Loader.dll for {other}");
            return;
        }
    };
    let Some(src) = find_loader(arch) else {
        println!("cargo:warning=html-host: WebView2Loader.dll was not found; the host will not start");
        return;
    };
    let out_dir = PathBuf::from(std::env::var("OUT_DIR").expect("OUT_DIR"));
    let dest = out_dir.join("..").join("..").join("..").join("WebView2Loader.dll");
    if let Err(err) = std::fs::copy(&src, &dest) {
        println!("cargo:warning=html-host: could not copy WebView2Loader.dll to {}: {err}", dest.display());
    }
    println!("cargo:rerun-if-changed={}", src.display());
}

fn find_loader(arch: &str) -> Option<PathBuf> {
    let mut homes = Vec::new();
    if let Ok(home) = std::env::var("CARGO_HOME") {
        homes.push(PathBuf::from(home));
    }
    if let Ok(profile) = std::env::var("USERPROFILE") {
        homes.push(PathBuf::from(profile).join(".cargo"));
    }
    for home in homes {
        let Ok(indexes) = std::fs::read_dir(home.join("registry").join("src")) else { continue };
        for index in indexes.flatten() {
            let Ok(crates) = std::fs::read_dir(index.path()) else { continue };
            for crate_dir in crates.flatten() {
                if !crate_dir.file_name().to_string_lossy().starts_with("webview2-com-sys-") {
                    continue;
                }
                let candidate = crate_dir.path().join(arch).join("WebView2Loader.dll");
                if candidate.is_file() {
                    return Some(candidate);
                }
            }
        }
    }
    None
}
