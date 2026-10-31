//! Draws client-ui over the Godot window and captures a fixed panel page for 3D boards.

use std::borrow::Cow;
use std::collections::VecDeque;
use std::io::{Read, Write};
use std::net::TcpStream;
use std::num::NonZeroIsize;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use http::Response;
use raw_window_handle::{HasWindowHandle, RawWindowHandle, Win32WindowHandle, WindowHandle};
use serde::Deserialize;
use webview2_com::CallDevToolsProtocolMethodCompletedHandler;
use windows::core::{w, HSTRING};
use windows::Win32::Foundation::{HWND, LPARAM, LRESULT, RECT, WPARAM};
use windows::Win32::Graphics::Gdi::{CombineRgn, CreateRectRgn, CreateRoundRectRgn, DeleteObject, RGN_OR, SetWindowRgn};
use windows::Win32::System::Com::{COINIT_APARTMENTTHREADED, CoInitializeEx};
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::UI::HiDpi::{DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2, SetProcessDpiAwarenessContext};
use windows::Win32::UI::Input::KeyboardAndMouse::SetFocus;
use windows::Win32::UI::WindowsAndMessaging::{
    CreateWindowExW, DefWindowProcW, DispatchMessageW, DestroyWindow, GW_CHILD, GW_HWNDNEXT, GWLP_HINSTANCE,
    GetClientRect, GetWindow, GetWindowLongPtrW, IsWindow, PeekMessageW, RegisterClassExW, SetWindowPos,
    TranslateMessage, CS_HREDRAW, CS_VREDRAW, MSG, PM_REMOVE, SWP_NOACTIVATE, SWP_NOZORDER, SWP_SHOWWINDOW,
    WM_DESTROY, WM_QUIT, WNDCLASSEXW, WS_EX_NOACTIVATE, WS_EX_TOOLWINDOW, WS_POPUP,
};
use wry::dpi::{PhysicalPosition, PhysicalSize};
use wry::{Rect, WebViewBuilder, WebViewExtWindows};

const PANEL_W: i32 = 1120;
const PANEL_H: i32 = 960;

#[derive(Deserialize, Clone, PartialEq, Eq)]
struct HitRect {
    x: i32,
    y: i32,
    w: i32,
    h: i32,
    r: i32,
}

struct ParentWindow {
    hwnd: NonZeroIsize,
    hinstance: Option<NonZeroIsize>,
}

impl HasWindowHandle for ParentWindow {
    fn window_handle(&self) -> Result<WindowHandle<'_>, raw_window_handle::HandleError> {
        let mut handle = Win32WindowHandle::new(self.hwnd);
        handle.hinstance = self.hinstance;
        Ok(unsafe { WindowHandle::borrow_raw(RawWindowHandle::Win32(handle)) })
    }
}

struct Launch {
    parent: isize,
    connect: String,
    ui: PathBuf,
}

fn launch() -> Launch {
    let mut parent = 0isize;
    let mut connect = String::new();
    let mut ui = PathBuf::new();
    let mut args = std::env::args().skip(1);
    while let Some(key) = args.next() {
        let value = args.next().unwrap_or_default();
        match key.as_str() {
            "--parent" => parent = value.parse().unwrap_or(0),
            "--connect" => connect = value,
            "--ui" => ui = PathBuf::from(value),
            _ => {}
        }
    }
    Launch { parent, connect, ui }
}

fn main() {
    let args = launch();
    if args.parent == 0 || args.connect.is_empty() || !args.ui.join("index.html").is_file() {
        eprintln!("html-host --parent <hwnd> --connect 127.0.0.1:<port> --ui <client-ui>");
        std::process::exit(1);
    }
    unsafe {
        let _ = SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
        let _ = CoInitializeEx(None, COINIT_APARTMENTTHREADED);
    }
    let mut stream = match connect(&args.connect) {
        Ok(stream) => stream,
        Err(err) => {
            eprintln!("html-host could not reach Godot: {err}");
            std::process::exit(1);
        }
    };
    let parent_bits = args.parent;
    let parent_hwnd = HWND(parent_bits as *mut std::ffi::c_void);
    let hinstance = NonZeroIsize::new(unsafe { GetWindowLongPtrW(parent_hwnd, GWLP_HINSTANCE) });
    let parent = ParentWindow {
        hwnd: NonZeroIsize::new(parent_bits).unwrap(),
        hinstance,
    };
    let before = direct_children(parent_hwnd);
    let ui_dir = args.ui.clone();
    let brand_dir = ui_dir.parent().unwrap_or(Path::new("")).join("client-godot").join("assets").join("branding");
    let outgoing: Arc<Mutex<VecDeque<String>>> = Arc::new(Mutex::new(VecDeque::new()));
    let regions: Arc<Mutex<Option<Vec<HitRect>>>> = Arc::new(Mutex::new(None));
    let capture_requested: Arc<Mutex<bool>> = Arc::new(Mutex::new(false));
    let capturing: Arc<Mutex<bool>> = Arc::new(Mutex::new(false));
    let focus_parent: Arc<Mutex<bool>> = Arc::new(Mutex::new(false));
    let focus_pulses: Arc<Mutex<VecDeque<Instant>>> = Arc::new(Mutex::new(VecDeque::new()));
    let panel_id: Arc<Mutex<String>> = Arc::new(Mutex::new(String::new()));
    let ipc_out = outgoing.clone();
    let ipc_regions = regions.clone();
    let ipc_capture = capture_requested.clone();
    let ipc_focus = focus_parent.clone();
    let ipc_pulses = focus_pulses.clone();
    let overlay = match WebViewBuilder::new()
        .with_transparent(true)
        .with_bounds(bounds(client_size(parent_hwnd)))
        .with_ipc_handler(move |request| {
            accept_ipc(
                request.body(),
                &ipc_out,
                &ipc_regions,
                &ipc_capture,
                &ipc_focus,
                &ipc_pulses,
            )
        })
        .with_custom_protocol("tukurium".into(), {
            let ui_dir = ui_dir.clone();
            let brand_dir = brand_dir.clone();
            move |_id, request| serve(&ui_dir, &brand_dir, request.uri().path())
        })
        .with_url("http://tukurium.localhost/index.html")
        .build_as_child(&parent)
    {
        Ok(webview) => webview,
        Err(err) => {
            eprintln!("html-host could not open WebView2: {err}");
            std::process::exit(1);
        }
    };
    // Clip every new child under Godot. WebView2 can create more than one HWND; any
    // unclipped sibling steals the whole client area and freezes world input.
    let mut overlay_children = new_children(parent_hwnd, &before);
    if overlay_children.is_empty() {
        let seek_until = Instant::now() + Duration::from_secs(2);
        while overlay_children.is_empty() && Instant::now() < seek_until {
            pump_window();
            overlay_children = new_children(parent_hwnd, &before);
            std::thread::sleep(Duration::from_millis(8));
        }
    }
    let overlay_child = overlay_children.first().copied().unwrap_or(HWND(std::ptr::null_mut()));

    // Keep the off-screen panel page off Godot's HWND tree so it can never cover input.
    let panel_host_hwnd = match create_panel_host() {
        Ok(hwnd) => hwnd,
        Err(err) => {
            eprintln!("html-host could not create panel host: {err}");
            std::process::exit(1);
        }
    };
    let panel_host = ParentWindow {
        hwnd: NonZeroIsize::new(panel_host_hwnd.0 as isize).expect("panel host"),
        hinstance: NonZeroIsize::new(unsafe { GetModuleHandleW(None).map(|h| h.0 as isize).unwrap_or(0) }),
    };
    let panel_ipc_out = outgoing.clone();
    let panel_capture = capture_requested.clone();
    let panel_focus = focus_parent.clone();
    let panel_pulses = focus_pulses.clone();
    let panel = match WebViewBuilder::new()
        .with_transparent(false)
        .with_bounds(Rect {
            position: PhysicalPosition::new(0, 0).into(),
            size: PhysicalSize::new(PANEL_W, PANEL_H).into(),
        })
        .with_ipc_handler(move |request| {
            accept_ipc(
                request.body(),
                &panel_ipc_out,
                &Mutex::new(None),
                &panel_capture,
                &panel_focus,
                &panel_pulses,
            )
        })
        .with_custom_protocol("tukurium".into(), {
            let ui_dir = ui_dir.clone();
            let brand_dir = brand_dir.clone();
            move |_id, request| serve(&ui_dir, &brand_dir, request.uri().path())
        })
        .with_url("http://tukurium.localhost/panel.html")
        .build_as_child(&panel_host)
    {
        Ok(webview) => webview,
        Err(err) => {
            eprintln!("html-host could not open panel WebView2: {err}");
            std::process::exit(1);
        }
    };
    unsafe {
        let _ = SetWindowPos(
            panel_host_hwnd,
            None,
            -32000,
            -32000,
            PANEL_W,
            PANEL_H,
            SWP_NOACTIVATE | SWP_SHOWWINDOW | SWP_NOZORDER,
        );
    }
    schedule_focus(&focus_parent, &focus_pulses);
    let mut child = overlay_child;
    let mut inbox = Vec::<u8>::new();
    let mut applied: Option<Vec<HitRect>> = None;
    let mut seeded = false;
    let mut sized = (0i32, 0i32);
    let seek_until = Instant::now() + Duration::from_secs(5);
    loop {
        if !unsafe { IsWindow(Some(parent_hwnd)) }.as_bool() {
            break;
        }
        pump_window();
        if child.0.is_null() {
            overlay_children = new_children(parent_hwnd, &before);
            child = overlay_children.first().copied().unwrap_or(HWND(std::ptr::null_mut()));
            if child.0.is_null() && Instant::now() > seek_until {
                eprintln!("html-host could not find the WebView window");
                break;
            }
        } else {
            // New WebView2 helper HWNDs can appear later; keep them clipped too.
            let latest = new_children(parent_hwnd, &before);
            if latest.len() > overlay_children.len() {
                overlay_children = latest;
                if let Some(rects) = applied.clone() {
                    for hwnd in &overlay_children {
                        apply_region(*hwnd, &rects);
                    }
                }
            }
        }
        let size = client_size(parent_hwnd);
        if size != sized && size.0 > 0 && size.1 > 0 {
            sized = size;
            let _ = overlay.set_bounds(bounds(size));
            if let Some(rects) = applied.clone() {
                for hwnd in &overlay_children {
                    apply_region(*hwnd, &rects);
                }
            }
        }
        if !overlay_children.is_empty() {
            if !seeded && sized.0 > 64 {
                let seed = vec![HitRect { x: 16, y: 16, w: (sized.0 - 32).max(1), h: 56, r: 18 }];
                for hwnd in &overlay_children {
                    apply_region(*hwnd, &seed);
                }
                applied = Some(seed);
                seeded = true;
            }
            if let Some(rects) = regions.lock().unwrap().clone() {
                if applied.as_ref() != Some(&rects) {
                    for hwnd in &overlay_children {
                        apply_region(*hwnd, &rects);
                    }
                    applied = Some(rects);
                }
            }
        }
        match read_available(&mut stream, &mut inbox) {
            Incoming::Closed => break,
            Incoming::Lines(lines) => {
                for line in lines {
                    let Ok(value) = serde_json::from_str::<serde_json::Value>(&line) else { continue };
                    match value.get("type").and_then(|kind| kind.as_str()) {
                        Some("panel_state") => {
                            if let Some(id) = value.get("id").and_then(|id| id.as_str()) {
                                *panel_id.lock().unwrap() = id.to_string();
                            }
                            let script = format!("window.tukurium&&window.tukurium.apply({line})");
                            let _ = panel.evaluate_script(&script);
                            *capture_requested.lock().unwrap() = true;
                        }
                        Some("panel_pointer") | Some("panel_key") => {
                            let script = format!("window.tukurium&&window.tukurium.apply({line})");
                            let _ = panel.evaluate_script(&script);
                            *capture_requested.lock().unwrap() = true;
                        }
                        Some("focus_parent") => {
                            schedule_focus(&focus_parent, &focus_pulses);
                        }
                        _ => {
                            let script = format!("window.tukurium&&window.tukurium.apply({line})");
                            let _ = overlay.evaluate_script(&script);
                        }
                    }
                }
            }
            Incoming::Waiting => {}
        }
        if *focus_parent.lock().unwrap() {
            *focus_parent.lock().unwrap() = false;
            let _ = unsafe { SetFocus(Some(parent_hwnd)) };
        }
        // At most a few spaced pulses — never SetFocus every frame (that blocks window drag).
        let due = {
            let mut pulses = focus_pulses.lock().unwrap();
            if pulses.front().is_some_and(|at| Instant::now() >= *at) {
                pulses.pop_front();
                true
            } else {
                false
            }
        };
        if due {
            let _ = unsafe { SetFocus(Some(parent_hwnd)) };
        }
        if *capture_requested.lock().unwrap() && !*capturing.lock().unwrap() {
            *capture_requested.lock().unwrap() = false;
            *capturing.lock().unwrap() = true;
            let out = outgoing.clone();
            let busy = capturing.clone();
            let id = panel_id.lock().unwrap().clone();
            let webview = panel.webview();
            let handler = CallDevToolsProtocolMethodCompletedHandler::create(Box::new(move |hr, result| {
                *busy.lock().unwrap() = false;
                if hr.is_err() {
                    return Ok(());
                }
                let text = result.to_string();
                if let Ok(value) = serde_json::from_str::<serde_json::Value>(&text) {
                    if let Some(data) = value.get("data").and_then(|data| data.as_str()) {
                        let message = serde_json::json!({
                            "type": "panel_frame",
                            "id": id,
                            "width": PANEL_W,
                            "height": PANEL_H,
                            "png": data,
                        });
                        out.lock().unwrap().push_back(message.to_string());
                    }
                }
                Ok(())
            }));
            let method = HSTRING::from("Page.captureScreenshot");
            let params = HSTRING::from("{\"format\":\"png\",\"fromSurface\":true}");
            let _ = unsafe { webview.CallDevToolsProtocolMethod(&method, &params, &handler) };
        }
        let messages: Vec<String> = outgoing.lock().unwrap().drain(..).collect();
        if write_lines(&mut stream, &messages).is_err() {
            break;
        }
        if messages.is_empty() {
            std::thread::sleep(Duration::from_millis(4));
        }
    }
    let _ = unsafe { DestroyWindow(panel_host_hwnd) };
}

fn schedule_focus(flag: &Mutex<bool>, pulses: &Mutex<VecDeque<Instant>>) {
    *flag.lock().unwrap() = true;
    let mut queue = pulses.lock().unwrap();
    if !queue.is_empty() {
        return;
    }
    let now = Instant::now();
    queue.push_back(now + Duration::from_millis(50));
    queue.push_back(now + Duration::from_millis(140));
}

fn create_panel_host() -> windows::core::Result<HWND> {
    let module = unsafe { GetModuleHandleW(None)? };
    let class_name = w!("tukurium_html_panel_host");
    let class = WNDCLASSEXW {
        cbSize: std::mem::size_of::<WNDCLASSEXW>() as u32,
        style: CS_HREDRAW | CS_VREDRAW,
        lpfnWndProc: Some(panel_host_proc),
        hInstance: module.into(),
        lpszClassName: class_name,
        ..Default::default()
    };
    unsafe {
        let _ = RegisterClassExW(&class);
        CreateWindowExW(
            WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE,
            class_name,
            w!("tukurium-panel"),
            WS_POPUP,
            -32000,
            -32000,
            PANEL_W,
            PANEL_H,
            None,
            None,
            Some(module.into()),
            None,
        )
    }
}

unsafe extern "system" fn panel_host_proc(hwnd: HWND, message: u32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    if message == WM_DESTROY {
        return LRESULT(0);
    }
    unsafe { DefWindowProcW(hwnd, message, wparam, lparam) }
}

fn connect(addr: &str) -> std::io::Result<TcpStream> {
    let started = Instant::now();
    loop {
        match TcpStream::connect(addr) {
            Ok(stream) => {
                stream.set_nodelay(true)?;
                stream.set_read_timeout(Some(Duration::from_millis(8)))?;
                return Ok(stream);
            }
            Err(_) if started.elapsed() < Duration::from_secs(8) => std::thread::sleep(Duration::from_millis(40)),
            Err(err) => return Err(err),
        }
    }
}

fn accept_ipc(
    body: &str,
    outgoing: &Mutex<VecDeque<String>>,
    regions: &Mutex<Option<Vec<HitRect>>>,
    capture: &Mutex<bool>,
    focus: &Mutex<bool>,
    pulses: &Mutex<VecDeque<Instant>>,
) {
    let Ok(value) = serde_json::from_str::<serde_json::Value>(body) else { return };
    match value.get("type").and_then(|kind| kind.as_str()) {
        Some("rects") => {
            if let Some(rects) = value.get("rects").and_then(|rects| serde_json::from_value(rects.clone()).ok()) {
                *regions.lock().unwrap() = Some(rects);
            }
        }
        Some("panel_capture_request") => {
            *capture.lock().unwrap() = true;
        }
        Some("focus_parent") => {
            schedule_focus(focus, pulses);
        }
        _ => outgoing.lock().unwrap().push_back(body.to_string()),
    }
}

fn serve(ui_dir: &Path, brand_dir: &Path, path: &str) -> Response<Cow<'static, [u8]>> {
    let rel = path.trim_start_matches('/');
    let (root, name) = if rel == "brand" || rel.starts_with("brand/") {
        (brand_dir, rel.trim_start_matches("brand/"))
    } else if rel.is_empty() || rel == "index.html" {
        (ui_dir, "index.html")
    } else {
        (ui_dir, rel)
    };
    if name.split(['/', '\\']).any(|part| part == "..") {
        return empty(404);
    }
    match std::fs::read(root.join(name)) {
        Ok(bytes) => Response::builder()
            .header("Content-Type", mime(name))
            .header("Cache-Control", "no-cache")
            .body(Cow::Owned(bytes))
            .unwrap_or_else(|_| empty(500)),
        Err(_) => empty(404),
    }
}

fn mime(path: &str) -> &'static str {
    if path.ends_with(".css") {
        "text/css; charset=utf-8"
    } else if path.ends_with(".js") {
        "text/javascript; charset=utf-8"
    } else if path.ends_with(".png") {
        "image/png"
    } else if path.ends_with(".html") {
        "text/html; charset=utf-8"
    } else {
        "application/octet-stream"
    }
}

fn empty(status: u16) -> Response<Cow<'static, [u8]>> {
    Response::builder().status(status).body(Cow::Owned(Vec::new())).unwrap_or_else(|_| Response::new(Cow::Owned(Vec::new())))
}

fn bounds(size: (i32, i32)) -> Rect {
    Rect {
        position: PhysicalPosition::new(0, 0).into(),
        size: PhysicalSize::new(size.0.max(1), size.1.max(1)).into(),
    }
}

fn client_size(hwnd: HWND) -> (i32, i32) {
    let mut rect = RECT::default();
    unsafe { let _ = GetClientRect(hwnd, &mut rect); }
    (rect.right - rect.left, rect.bottom - rect.top)
}

fn direct_children(parent: HWND) -> Vec<isize> {
    let mut list = Vec::new();
    let mut cursor = unsafe { GetWindow(parent, GW_CHILD) };
    for _ in 0..64 {
        let Ok(hwnd) = cursor else { break };
        if hwnd.0.is_null() { break; }
        list.push(hwnd.0 as isize);
        cursor = unsafe { GetWindow(hwnd, GW_HWNDNEXT) };
    }
    list
}

fn new_children(parent: HWND, before: &[isize]) -> Vec<HWND> {
    direct_children(parent)
        .into_iter()
        .filter(|key| !before.contains(key))
        .map(|key| HWND(key as *mut std::ffi::c_void))
        .collect()
}

fn apply_region(hwnd: HWND, rects: &[HitRect]) {
    if hwnd.0.is_null() {
        return;
    }
    unsafe {
        let mut combined = CreateRectRgn(0, 0, 0, 0);
        let mut any = false;
        for rect in rects {
            if rect.w <= 0 || rect.h <= 0 { continue; }
            let piece = if rect.r > 0 {
                CreateRoundRectRgn(rect.x, rect.y, rect.x + rect.w, rect.y + rect.h, rect.r * 2, rect.r * 2)
            } else {
                CreateRectRgn(rect.x, rect.y, rect.x + rect.w, rect.y + rect.h)
            };
            if !any {
                let _ = DeleteObject(combined.into());
                combined = piece;
                any = true;
            } else {
                CombineRgn(Some(combined), Some(combined), Some(piece), RGN_OR);
                let _ = DeleteObject(piece.into());
            }
        }
        let _ = SetWindowRgn(hwnd, Some(combined), true);
    }
}

fn pump_window() {
    unsafe {
        let mut message = MSG::default();
        while PeekMessageW(&mut message, None, 0, 0, PM_REMOVE).as_bool() {
            if message.message == WM_QUIT { return; }
            let _ = TranslateMessage(&message);
            DispatchMessageW(&message);
        }
    }
}

enum Incoming {
    Waiting,
    Closed,
    Lines(Vec<String>),
}

fn read_available(stream: &mut TcpStream, inbox: &mut Vec<u8>) -> Incoming {
    let mut buf = [0u8; 65536];
    match stream.read(&mut buf) {
        Ok(0) => Incoming::Closed,
        Ok(n) => {
            inbox.extend_from_slice(&buf[..n]);
            let mut lines = Vec::new();
            while let Some(at) = inbox.iter().position(|b| *b == b'\n') {
                let raw = inbox.drain(..=at).collect::<Vec<_>>();
                if let Ok(text) = std::str::from_utf8(&raw) {
                    let line = text.trim();
                    if !line.is_empty() {
                        lines.push(line.to_string());
                    }
                }
            }
            if lines.is_empty() { Incoming::Waiting } else { Incoming::Lines(lines) }
        }
        Err(err) if err.kind() == std::io::ErrorKind::WouldBlock || err.kind() == std::io::ErrorKind::TimedOut => Incoming::Waiting,
        Err(_) => Incoming::Closed,
    }
}

fn write_lines(stream: &mut TcpStream, lines: &[String]) -> std::io::Result<()> {
    for line in lines {
        stream.write_all(line.as_bytes())?;
        stream.write_all(b"\n")?;
    }
    if !lines.is_empty() {
        stream.flush()?;
    }
    Ok(())
}
