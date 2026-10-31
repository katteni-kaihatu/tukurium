macro_rules! eprintln {
    ($($arg:tt)*) => { crate::console::log(format_args!($($arg)*)) };
}
mod console;
mod assets;
mod edit_sessions;
mod script_documents;
mod graph_documents;
mod management;
mod media_clock;
mod persistence;
mod previews;
mod projects;
mod state_rules;
use kokoverse_core::{WorldModel, replication::REGISTRY};
use kokoverse_protocol::{
    AvatarPose, GrabView, InteractionRay, ObjectPreview, ParticipantView, PlayerInput,
    PositionSpace, SessionChatMessage, TransformCommand,
};
use kokoverse_protocol::{
    Envelope, ReplicatedWorld, ReplicationCommit, VERSION, WorldCommand, read_frame, write_frame,
};
use serde_json::{Value, json};
use std::{
    collections::{HashMap, VecDeque},
    time::Duration,
};
use tokio::{
    net::{TcpListener, TcpStream},
    sync::mpsc,
};
use uuid::Uuid;

enum Event {
    Connected(u64, bool, mpsc::Sender<Value>),
    Message(u64, Value),
    Closed(u64),
    ServiceDone(
        u64,
        String,
        String,
        u64,
        Result<management::Completion, String>,
    ),
}

async fn connection(stream: TcpStream, id: u64, adapter: bool, events: mpsc::Sender<Event>) {
    let (mut reader, mut writer) = stream.into_split();
    let (out, mut incoming) = mpsc::channel::<Value>(64);
    if events
        .send(Event::Connected(id, adapter, out))
        .await
        .is_err()
    {
        return;
    }
    let task = tokio::spawn(async move {
        while let Some(value) = incoming.recv().await {
            match tokio::time::timeout(Duration::from_secs(5), write_frame(&mut writer, &value))
                .await
            {
                Ok(Ok(())) => {}
                _ => break,
            }
        }
    });
    loop {
        tokio::select! {
            result = read_frame(&mut reader) => {
                match result {
                    Ok(value) => if events.send(Event::Message(id, value)).await.is_err() { break; },
                    Err(_) => break,
                }
            },
            _ = events.closed() => break,
            _ = tokio::time::sleep(Duration::from_millis(100)) => if task.is_finished() { break; },
        }
    }
    task.abort();
    let _ = events.send(Event::Closed(id)).await;
}

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
enum Origin {
    Local(u64),
    Peer(String),
}

struct Engine {
    service: Option<management::Service>,
    service_user: Value,
    active_session: Option<Value>,
    /// Local project slug whose world.json is auto-saved when the session ends.
    active_project: Option<String>,
    service_generation: u64,
    service_jobs: usize,
    transport_ready: bool,
    managed_verified: bool,
    managed_peers: HashMap<String, String>,
    managed_aliases: HashMap<String, Vec<String>>,
    managed_placed: HashMap<String, std::time::Instant>,
    edit_sessions: kokoverse_core::edit_sessions::EditSessions,
    documents: script_documents::Bridge,
    graph_documents: graph_documents::Bridge,
    remote_edit_sessions: Vec<kokoverse_protocol::EditSession>,
    last_edit_sessions: Value,
    clock: media_clock::ClockSync,
    assets: assets::Assets,
    local_ray: Option<InteractionRay>,
    remote_rays: HashMap<String, InteractionRay>,
    rays_dirty: bool,
    grab_owner: Option<u64>,
    grab_command: Option<String>,
    last_grab: Option<GrabView>,
    previews: previews::Previews,
    model: WorldModel,
    host: bool,
    automatic_role: bool,
    host_peer: String,
    session: String,
    epoch: String,
    sequence: u64,
    synced: bool,
    adapter: Option<u64>,
    clients: HashMap<u64, mpsc::Sender<Value>>,
    pending: HashMap<String, (u64, std::time::Instant, String)>,
    deferred_results: HashMap<String, Value>,
    tickets: HashMap<u64, (String, String, Vec<Origin>)>,
    inflight: HashMap<String, u64>,
    peer: String,
    input_owner: Option<(u64, std::time::Instant)>,
    last_tick: std::time::Instant,
    pose_sequence: u64,
    remote_epochs: HashMap<String, String>,
    remote_seen: HashMap<String, std::time::Instant>,
    chat_last_sent: HashMap<String, std::time::Instant>,
    outcomes: HashMap<String, Value>,
    order: VecDeque<String>,
    last_script_status: Value,
    last_drive_frame: Option<kokoverse_protocol::DriveFrame>,
    remote_script_status: Vec<kokoverse_protocol::ScriptStatus>,
}

impl Engine {
    fn service_state(&self) -> Value {
        json!({"kind":"service_state","enabled":self.service.is_some(),"user":self.service_user,
            "session":self.active_session.as_ref().map(|s|json!({"id":s["session"]["id"],"name":s["session"]["name"],"host":s["host"]})),
            "project":self.active_project.as_ref().map(|slug|json!({"slug":slug,"local":true}))})
    }
    fn start_service_job(
        &mut self,
        id: u64,
        request_id: String,
        operation: String,
        body: Value,
        events: &mpsc::Sender<Event>,
    ) {
        let Some(service) = self.service.clone() else {
            return;
        };
        if self.service_jobs >= 16 {
            self.reply(Origin::Local(id),json!({"kind":"service_result","request_id":request_id,"action":operation,"ok":false,"message":"Too many pending requests"}));
            return;
        }
        self.service_jobs += 1;
        let events = events.clone();
        let generation = self.service_generation;
        tokio::spawn(async move {
            let result = service.execute(body).await;
            let _ = events
                .send(Event::ServiceDone(
                    id, request_id, operation, generation, result,
                ))
                .await;
        });
    }
    fn reset_managed_world(
        &mut self,
        session: String,
        host: bool,
        host_peer: String,
        model: WorldModel,
    ) {
        self.cancel_grab();
        self.clear_remote_presence();
        self.pending.clear();
        self.deferred_results.clear();
        self.tickets.clear();
        self.inflight.clear();
        self.outcomes.clear();
        self.order.clear();
        self.previews = previews::Previews::default();
        self.edit_sessions = Default::default();
        self.documents = Default::default();
        self.remote_edit_sessions.clear();
        self.last_edit_sessions = Value::Null;
        self.remote_script_status.clear();
        self.chat_last_sent.clear();
        self.last_script_status = Value::Null;
        self.last_drive_frame = None;
        self.managed_peers.clear();
        self.managed_placed.clear();
        self.input_owner = None;
        self.model = model;
        self.session = session;
        self.host = host;
        self.managed_verified = host;
        self.automatic_role = false;
        self.host_peer = host_peer;
        self.peer = self
            .active_session
            .as_ref()
            .and_then(|s| s["peer"].as_str())
            .unwrap_or("lobby")
            .into();
        self.synced = host;
        self.epoch = if host {
            Uuid::new_v4().to_string()
        } else {
            String::new()
        };
        self.sequence = 0;
        self.pose_sequence = 0;
        self.adapter = None;
        self.transport_ready = false;
        self.clock = media_clock::ClockSync::new();
        self.last_tick = std::time::Instant::now();
        let name = self.service_user["name"]
            .as_str()
            .unwrap_or("Guest")
            .to_string();
        let _ = self.model.update_participant(ParticipantView {
            id: "local".into(),
            name,
            avatar_texture: None,
            pose: AvatarPose {
                position: [0., 0., 3.],
                yaw: 0.,
                pitch: 0.,
            },
        });
        self.model.tick();
        let _ = self.model.enable_local_player("local");
    }
    fn sync_grab(&mut self) {
        let view = self.model.grab_view();
        if let Some(owner) = self.grab_owner {
            if let Some(grab) = &view {
                self.previews.set(
                    format!("local:{owner}"),
                    Some(grab.preview.clone()),
                    std::time::Instant::now(),
                );
            } else {
                self.previews.remove(&format!("local:{owner}"));
                self.grab_owner = None;
            }
        }
        if view != self.last_grab {
            self.last_grab = view.clone();
            self.ui(json!({"kind":"grab_state","grab":view}));
        }
        let ray = self.model.interaction_ray();
        if ray != self.local_ray {
            self.local_ray = ray;
            self.rays_dirty = true;
        }
        if self.rays_dirty {
            self.rays_dirty = false;
            let mut rays: Vec<Value> = self
                .remote_rays
                .iter()
                .map(|(owner, ray)| json!({"owner":owner,"ray":ray}))
                .collect();
            if let Some(ray) = &self.local_ray {
                rays.push(json!({"owner":"local","ray":ray}));
            }
            self.ui(json!({"kind":"interaction_rays","rays":rays}));
        }
    }
    fn cancel_grab(&mut self) {
        self.grab_command = None;
        self.model.cancel_grab();
        self.sync_grab();
    }
    fn dispatch_command(&mut self, id: u64, mut command: WorldCommand, grab: bool) {
        let requested_id = command.command_id().to_string();
        if !self.host {
            command.set_command_id(Uuid::new_v4().to_string());
        }
        if grab {
            self.grab_command = Some(requested_id.clone());
        }
        if self.host {
            self.queue_command(&format!("local-{id}"), command, Origin::Local(id));
        } else if self.pending.len() < 128 {
            self.pending.insert(
                command.command_id().to_string(),
                (id, std::time::Instant::now(), requested_id),
            );
            let peer = self.host_peer.clone();
            self.network(Some(&peer), serde_json::to_value(command).unwrap());
        } else {
            self.reply(Origin::Local(id),json!({"kind":"result","command_id":requested_id,"ok":false,"message":"Too many pending edits"}));
        }
    }
    fn handle_grab(&mut self, id: u64, body: &Value) {
        match body["action"].as_str().unwrap_or("") {
            "begin" => {
                let result = if self.grab_owner.is_some()
                    || self.previews.local().is_some()
                    || self.input_owner.is_some_and(|(owner, _)| owner != id)
                {
                    Err("Another local interaction is active".into())
                } else {
                    self.previews.prune(&self.model, std::time::Instant::now());
                    self.model.set_collision_previews(self.previews.positions());
                    self.model.begin_grab()
                };
                if let Err(message) = result {
                    let e = self.envelope(json!({"kind":"grab_error","message":message}));
                    self.send(id, e);
                } else {
                    self.grab_command = None;
                    self.grab_owner = Some(id);
                    self.sync_grab();
                }
            }
            "distance" if self.grab_owner == Some(id) => {
                if let Some(delta) = body["delta"].as_f64() {
                    self.model.adjust_grab_distance(delta);
                }
            }
            "rotate" if self.grab_owner == Some(id) => {
                if let Ok(delta) = serde_json::from_value::<[f64; 2]>(body["delta"].clone()) {
                    self.model
                        .rotate_grab(delta, body["vertical"].as_bool().unwrap_or(false));
                }
            }
            "scale" if self.grab_owner == Some(id) => {
                if let Some(factor) = body["factor"].as_f64() {
                    self.model.scale_grab(factor);
                }
            }
            "align" if self.grab_owner == Some(id) => self.model.align_grab(),
            "cancel" if self.grab_owner == Some(id) => self.cancel_grab(),
            "release" if self.grab_owner == Some(id) => {
                if let Some((p, local)) = self.model.release_grab() {
                    self.sync_grab();
                    self.dispatch_command(
                        id,
                        WorldCommand::Transform {
                            command: TransformCommand {
                                command_id: body["command_id"]
                                    .as_str()
                                    .filter(|id| !id.is_empty() && id.len() <= 80)
                                    .map(str::to_string)
                                    .unwrap_or_else(|| Uuid::new_v4().to_string()),
                                target: p.target,
                                expected_position_revision: p.expected_revision,
                                expected_rotation_revision: p.expected_rotation_revision.unwrap(),
                                expected_scale_revision: p.expected_scale_revision.unwrap(),
                                space: PositionSpace::Parent,
                                position: local.translation,
                                rotation: local.rotation,
                                scale: local.scale,
                            },
                        },
                        true,
                    );
                }
            }
            _ => {}
        }
    }
    fn envelope(&mut self, body: Value) -> Value {
        self.sequence += 1;
        json!(Envelope {
            protocol_version: VERSION,
            session_id: self.session.clone(),
            authority_epoch: self.epoch.clone(),
            sequence: self.sequence.to_string(),
            body
        })
    }
    fn send(&mut self, id: u64, value: Value) {
        if self
            .clients
            .get(&id)
            .is_some_and(|c| c.try_send(value).is_err())
        {
            self.clients.remove(&id); // Slow readers reconnect for a fresh snapshot.
        }
    }
    fn ui(&mut self, body: Value) {
        let value = self.envelope(body);
        let ids: Vec<_> = self
            .clients
            .keys()
            .copied()
            .filter(|id| Some(*id) != self.adapter)
            .collect();
        for id in ids {
            self.send(id, value.clone());
        }
    }
    fn network(&mut self, to: Option<&str>, body: Value) {
        let envelope = self.envelope(body);
        if let Some(id) = self.adapter {
            self.send(id, json!({"type":"send", "to":to, "body":envelope}));
        }
    }
    fn state(&mut self) -> Value {
        json!({"kind":"snapshot", "snapshot": self.model.snapshot(), "editable":self.synced && (self.service.is_none() || self.managed_verified),
            "chat":self.model.chat_messages(),
            "role":if self.host {"host"} else {"guest"},
            "script_statuses":if self.host {self.model.script_statuses()} else {self.remote_script_status.clone()},
            "drive_frame":self.model.drive_frame()})
    }
    /// The static half of what state() used to carry on every
    /// publish: component schemas and script templates are fixed
    /// for the whole session, so they are sent once per UI
    /// connection (at hello) as a `catalog` message instead of
    /// being rebuilt, cloned to every UI client, and re-parsed on
    /// each world change. Clients keep the last catalog they
    /// received; snapshot messages no longer contain these keys.
    fn catalog() -> Value {
        json!({"kind":"catalog",
            "component_schemas":REGISTRY.schemas(),
            "script_templates":[{"name":"Rotator","source":kokoverse_core::scripting::ROTATOR},
                {"name":"ClickColor","source":kokoverse_core::scripting::CLICK_COLOR},
                {"name":"Countdown Camera · Lua","source":kokoverse_core::scripting::COUNTDOWN_CAMERA_LUA},
                {"name":"Countdown Camera · Nodes","source":kokoverse_core::scripting::COUNTDOWN_CAMERA_NODES}]})
    }
    fn publish_state(&mut self) {
        self.previews.prune(&self.model, std::time::Instant::now());
        let state = self.state();
        self.ui(state);
    }
    fn publish_presence(&mut self) {
        self.ui(
            json!({"kind":"presence", "self_id":"local", "participants":self.model.participants(), "local_motion":self.model.local_motion()}),
        );
    }
    fn publish_chat(&mut self) {
        self.ui(json!({"kind":"chat_state", "messages":self.model.chat_messages()}));
    }
    fn submit_chat(&mut self, sender_id: &str, text: &str, origin: Origin) {
        if !self.host || !self.synced || (self.service.is_some() && match &origin {
            Origin::Local(_) => !self.managed_verified,
            Origin::Peer(peer) => !self.managed_peers.contains_key(peer),
        }) {
            self.reply(origin,json!({"kind":"chat_error","message":"Join the session before sending chat"}));
            return;
        }
        let Some(sender) = self.model.participants().into_iter().find(|person| person.id == sender_id) else {
            self.reply(origin,json!({"kind":"chat_error","message":"Participant is not ready"}));
            return;
        };
        if self.chat_last_sent.get(sender_id).is_some_and(|last| last.elapsed() < Duration::from_millis(300)) {
            self.reply(origin,json!({"kind":"chat_error","message":"Wait before sending another message"}));
            return;
        }
        let message = SessionChatMessage {
            id: Uuid::new_v4().to_string(), sender_id: sender_id.into(), sender_name: sender.name,
            text: text.trim().into(),
            at_millis: std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap_or_default().as_millis() as u64,
        };
        match self.model.append_chat(message.clone()) {
            Ok(true) => {
                self.chat_last_sent.insert(sender_id.into(),std::time::Instant::now());
                self.publish_chat();
                self.network(None,json!({"kind":"chat_message","message":message}));
            }
            Ok(false) => {}
            Err(error) => self.reply(origin,json!({"kind":"chat_error","message":error})),
        }
    }
    fn clear_remote_presence(&mut self) {
        self.managed_peers.clear();
        self.managed_aliases.clear();
        self.remote_edit_sessions.clear();
        self.remote_rays.clear();
        self.rays_dirty = true;
        self.cancel_grab();
        self.previews.clear();
        for id in self.remote_seen.keys() {
            self.model.remove_participant(id);
            self.chat_last_sent.remove(id);
        }
        self.remote_seen.clear();
        self.remote_epochs.clear();
    }
    fn send_pose(&mut self) {
        if self.adapter.is_none() {
            return;
        }
        self.pose_sequence += 1;
        let Some(local) = self.model.local_player() else {
            return;
        };
        let body =
            self.envelope(json!({"kind":"pose", "name":local.name, "pose":local.pose, "avatar_texture":local.avatar_texture,"preview":self.previews.local(),"ray":self.local_ray}));
        if let Some(id) = self.adapter {
            self.send(
                id,
                json!({"type":"latest", "sequence":self.pose_sequence.to_string(), "body":body}),
            );
        }
    }
    fn status(&mut self, message: &str) {
        eprintln!("{message}");
        if !self.synced {
            self.cancel_grab();
        }
        self.ui(json!({"kind":"status", "message":message, "editable":self.synced && (self.service.is_none() || self.managed_verified)}));
    }
    fn request_snapshot(&mut self) {
        let peer = self.host_peer.clone();
        self.network(Some(&peer), json!({"kind":"snapshot_request"}));
    }
    fn reply(&mut self, origin: Origin, mut result: Value) {
        if matches!(origin, Origin::Local(_)) && result.get("snapshot").is_some() {
            result["snapshot"] = json!(self.model.snapshot());
        }
        if let Origin::Local(id) = &origin
            && self.grab_owner == Some(*id)
            && result["command_id"].as_str() == self.grab_command.as_deref()
        {
            self.grab_command = None;
            self.cancel_grab();
        }
        match origin {
            Origin::Local(id) => {
                let e = self.envelope(result);
                self.send(id, e);
            }
            Origin::Peer(peer) => self.network(Some(&peer), result),
        }
    }
    fn queue_command(&mut self, requester: &str, mut command: WorldCommand, origin: Origin) {
        let command_id = command.command_id().to_string();
        let actor = if self.service.is_some() {
            let user = match &origin {
                Origin::Local(_) => self.service_user["id"].as_str().map(str::to_owned),
                Origin::Peer(peer) => self.managed_peers.get(peer).cloned(),
            };
            let Some(user) = user else {
                self.reply(origin,json!({"kind":"result","command_id":command_id,"ok":false,"message":"User identity is still being verified"}));
                return;
            };
            // Item attribution and library licenses do not restrict shared-world editing.
            // Keep verified authorship and the normal revision/edit-session checks below.
            let interaction = matches!(&command, WorldCommand::Playback { .. })
                || matches!(&command, WorldCommand::Script { command }
                    if matches!(command.action, kokoverse_protocol::ScriptAction::Interact | kokoverse_protocol::ScriptAction::Press | kokoverse_protocol::ScriptAction::Release));
            if interaction {
                None
            } else {
                Some(kokoverse_protocol::ItemEditor {
                    user_id: user,
                    edited_at: kokoverse_asset_server::now(),
                })
            }
        } else {
            None
        };
        let key = format!("{requester}:{command_id}");
        if let Some(mut result) = self.outcomes.get(&key).cloned() {
            if result["ok"] == false {
                result["snapshot"] = json!(REGISTRY.encode_world(&self.model.snapshot()));
            }
            self.reply(origin, result);
            return;
        }
        if let Some(&ticket) = self.inflight.get(&key) {
            // Redelivery of a command that is still being processed
            // (reliable-delivery resend, adapter reconnect): remember
            // this origin as well so the result reaches every sender
            // instead of the resender waiting for a timeout.
            if let Some((_, _, origins)) = self.tickets.get_mut(&ticket)
                && !origins.contains(&origin)
            {
                origins.push(origin);
            }
            return;
        }
        self.edit_sessions
            .prune(&self.model.snapshot(), std::time::Instant::now());
        if let Err(message) = self.edit_sessions.check_command(requester, &command) {
            self.reply(
                origin,
                json!({"kind":"result","command_id":command_id,"ok":false,"message":message}),
            );
            return;
        }
        if let WorldCommand::Edit { edit } = &mut command
            && edit.field_id == "panel_pin"
            && edit.value["user_id"] == "$self"
        {
            edit.value["user_id"] = json!(if matches!(origin, Origin::Local(_)) {
                "local".to_string()
            } else {
                requester.to_string()
            });
        }
        // Asset references can be committed before their bytes arrive.
        // Missing bytes are resolved by the bounded asset waiters, not world edits.
        let queued = if matches!(&command, WorldCommand::Script { command } if matches!(command.action, kokoverse_protocol::ScriptAction::Interact | kokoverse_protocol::ScriptAction::Press | kokoverse_protocol::ScriptAction::Release)) {
            self.model.enqueue_script_interaction_as(command, requester.to_string())
        } else if let Some(editor) = actor {
            self.model.enqueue_as(command, editor)
        } else {
            self.model.enqueue(command)
        };
        match queued {
            Ok(ticket) => {
                self.inflight.insert(key.clone(), ticket);
                self.tickets.insert(ticket, (key, command_id, vec![origin]));
            }
            Err(message) => self.reply(
                origin,
                json!({"kind":"result", "command_id":command_id, "ok":false, "message":message}),
            ),
        }
    }
    fn tick(&mut self) {
        self.update_engine_clock();
        self.model.set_drive_clock_ready(self.synced && (self.host || self.clock.ready()));
        self.model.set_script_authority(self.host);
        self.model.set_media_time(self.clock.now());
        let presence_revision = self.model.presence_revision();
        let now = std::time::Instant::now();
        let elapsed = now.duration_since(self.last_tick);
        self.last_tick = now;
        if self
            .input_owner
            .is_some_and(|(_, last)| last.elapsed() > Duration::from_millis(250))
        {
            if self.grab_command.is_none() {
                self.cancel_grab();
            }
            self.input_owner = None;
            self.model.stop_player_input();
        }
        self.previews.prune(&self.model, now);
        self.model.set_collision_previews(self.previews.positions());
        let outcomes = self.model.advance(elapsed);
        for capture in self.model.take_camera_captures() {
            let body = json!({"kind":"camera_capture","target":capture.target});
            if let Some(client) = capture.requester.strip_prefix("local-").and_then(|id| id.parse::<u64>().ok()) {
                let envelope = self.envelope(body);
                self.send(client, envelope);
            } else if let Some((peer, epoch)) = capture.requester.split_once(':')
                && state_rules::epoch_matches(&self.remote_epochs, peer, epoch)
            {
                self.network(Some(peer), body);
            }
        }
        self.sync_grab();
        let frame = self.model.drive_frame();
        if self.last_drive_frame.as_ref().is_none_or(|last| last.objects != frame.objects || last.statuses != frame.statuses || last.transforms != frame.transforms) {
            self.ui(json!({"kind":"drive_frame", "frame":frame}));
            self.last_drive_frame = Some(frame);
        }
        let mut replies = Vec::new();
        let mut changed = false;
        for outcome in outcomes {
            if outcome.ticket == 0 {
                if let Ok(commit) = outcome.result {
                    changed = true;
                    self.network(None, json!({"kind":"component_commit", "commit":REGISTRY.encode_commit(&commit)}));
                }
                continue;
            }
            let Some((key, command_id, origins)) = self.tickets.remove(&outcome.ticket) else {
                continue;
            };
            self.inflight.remove(&key);
            let result = match outcome.result {
                Ok(commit) => {
                    changed = true;
                    let result = json!({"kind":"result", "command_id":command_id, "ok":true, "world_revision":commit.world_revision, "selected":outcome.selected});
                    self.network(None, json!({"kind":"component_commit", "commit":REGISTRY.encode_commit(&commit)}));
                    result
                }
                Err(message) => {
                    json!({"kind":"result", "command_id":command_id, "ok":false, "message":message, "snapshot":REGISTRY.encode_world(&self.model.snapshot())})
                }
            };
            if state_rules::outcome_cache_full(self.order.len())
                && let Some(old) = self.order.pop_front()
            {
                self.outcomes.remove(&old);
            }
            self.order.push_back(key.clone());
            let mut cached = result.clone();
            if let Some(object) = cached.as_object_mut() {
                object.remove("snapshot");
            }
            self.outcomes.insert(key, cached);
            for origin in origins {
                replies.push((origin, result.clone()));
            }
        }
        if changed {
            self.publish_state();
        }
        let statuses = json!(if self.host {
            self.model.script_statuses()
        } else {
            self.remote_script_status.clone()
        });
        if statuses != self.last_script_status {
            self.last_script_status = statuses.clone();
            self.ui(json!({"kind":"script_statuses","statuses":statuses}));
            if self.host {
                self.network(None, json!({"kind":"script_statuses","statuses":statuses}));
            }
        }
        for (origin, result) in replies {
            self.reply(origin, result);
        }
        if self.model.presence_revision() != presence_revision {
            self.publish_presence();
        }
        self.previews.prune(&self.model, std::time::Instant::now());
        if self.previews.dirty {
            self.previews.dirty = false;
            self.ui(self.previews.body());
        }
        self.publish_edit_sessions();
    }
    fn flush_results(&mut self) {
        let revision = self.model.snapshot().world_revision.parse::<u64>().unwrap();
        let ready: Vec<_> = self
            .deferred_results
            .iter()
            .filter(|(_, result)| {
                result["world_revision"]
                    .as_str()
                    .and_then(|r| r.parse::<u64>().ok())
                    .is_none_or(|r| r <= revision)
            })
            .map(|(id, _)| id.clone())
            .collect();
        for command in ready {
            let mut result = self.deferred_results.remove(&command).unwrap();
            if let Some((id, _, requested_id)) = self.pending.remove(&command) {
                result["command_id"] = json!(requested_id);
                if result.get("snapshot").is_some() {
                    result["snapshot"] = json!(self.model.snapshot());
                }
                self.reply(Origin::Local(id), result);
            }
        }
    }
    fn handle_ui(&mut self, id: u64, value: Value) {
        let Ok(envelope) = serde_json::from_value::<Envelope>(value) else {
            return;
        };
        if envelope.protocol_version != VERSION || envelope.session_id != self.session {
            return;
        }
        if envelope.body["kind"] == "hello" {
            let e = self.envelope(Self::catalog());
            self.send(id, e);
            let state = self.state();
            let e = self.envelope(state);
            self.send(id, e);
            self.publish_presence();
            self.ui(self.previews.body());
            let view = self.model.grab_view();
            let e = self.envelope(json!({"kind":"grab_state","grab":view}));
            self.send(id, e);
            let body = json!({"kind":"edit_sessions","sessions":if self.host {self.edit_sessions.views()}else{self.remote_edit_sessions.clone()}});
            let envelope = self.envelope(body);
            self.send(id, envelope);
            return;
        }
        if envelope.body["kind"] == "chat_send" {
            if !state_rules::accepts_local(
            self.synced,
            self.service.is_some(),
            self.managed_verified,
            &envelope.authority_epoch,
            &self.epoch,
        ) {
                self.reply(Origin::Local(id),json!({"kind":"chat_error","message":"Join the session before sending chat"}));
            } else if let Some(text) = envelope.body["text"].as_str() {
                if self.host {
                    self.submit_chat("local",text,Origin::Local(id));
                } else {
                    let peer = self.host_peer.clone();
                    self.network(Some(&peer),json!({"kind":"chat_send","text":text}));
                }
            }
            return;
        }
        if envelope.body["kind"].as_str().is_some_and(|kind|kind.starts_with("script_graph")) {
            if self.synced && envelope.authority_epoch == self.epoch { self.graph_document_message(Origin::Local(id), &envelope.body); }
            return;
        }
        if envelope.body["kind"].as_str().is_some_and(|kind|kind.starts_with("script_document")) {
            if self.synced && envelope.authority_epoch == self.epoch { self.script_document_message(Origin::Local(id), &envelope.body); }
            return;
        }
        if envelope.body["kind"] == "edit_session" {
            if self.synced && envelope.authority_epoch == self.epoch {
                self.edit_session(id, &envelope.body);
            }
            return;
        }
        if envelope.body["kind"] == "clock_ping" {
            if self.synced && envelope.authority_epoch == self.epoch {
                self.clock_message(Origin::Local(id), &envelope.body);
            }
            return;
        }
        if envelope.body["kind"]
            .as_str()
            .is_some_and(|k| k.starts_with("asset_"))
        {
            if self.synced && envelope.authority_epoch == self.epoch {
                self.asset_message(Origin::Local(id), &envelope.body);
            }
            return;
        }
        if envelope.body["kind"] == "grab" {
            if self.synced && (self.service.is_none() || self.managed_verified) && envelope.authority_epoch == self.epoch {
                self.handle_grab(id, &envelope.body);
            }
            return;
        }
        if envelope.body["kind"] == "drag_preview" {
            if self.grab_owner.is_some() {
                return;
            }
            let owner = format!("local:{id}");
            if self
                .previews
                .local_owner()
                .is_some_and(|current| current != owner)
            {
                return;
            }
            let preview = serde_json::from_value::<ObjectPreview>(envelope.body["preview"].clone())
                .ok()
                .filter(|preview| {
                    self.synced
                        && envelope.authority_epoch == self.epoch
                        && self.model.accepts_preview(preview)
                        && (self.service.is_none() || self.managed_verified)
                });
            self.previews.set(owner, preview, std::time::Instant::now());
            return;
        }
        if envelope.body["kind"] == "player_input" {
            let Ok(input) = serde_json::from_value::<PlayerInput>(envelope.body["input"].clone())
            else {
                return;
            };
            if !kokoverse_core::locomotion::valid_input(&input) {
                return;
            }
            if self.input_owner.is_some_and(|(owner, last)| {
                owner != id && last.elapsed() <= Duration::from_millis(250)
            }) {
                return;
            }
            if self.model.set_player_input(input.clone()).is_ok() {
                self.input_owner = input.active.then_some((id, std::time::Instant::now()));
            }
            return;
        }
        if envelope.body["kind"] == "profile" {
            if let Some(name) = envelope.body["name"].as_str() {
                let name = name.trim();
                if !name.is_empty()
                    && name.chars().count() <= 40
                    && let Some(mut local) = self.model.local_player()
                {
                    local.name = name.into();
                    if let Some(texture) = envelope.body.get("avatar_texture") {
                        match texture.as_str() {
                            Some(id) if self.assets.is_avatar_texture(id) => {
                                local.avatar_texture = Some(id.into())
                            }
                            None if texture.is_null() => local.avatar_texture = None,
                            _ => return,
                        }
                    }
                    let _ = self.model.update_participant(local);
                }
            }
            return;
        }
        if envelope.body["kind"] != "edit"
            && envelope.body["kind"] != "structure"
            && envelope.body["kind"] != "transform"
            && envelope.body["kind"] != "playback"
            && envelope.body["kind"] != "script"
        {
            return;
        }
        let requested_id = envelope.body["edit"]["command_id"]
            .as_str()
            .or_else(|| envelope.body["command"]["command_id"].as_str())
            .unwrap_or("")
            .to_owned();
        if !state_rules::accepts_local(
            self.synced,
            self.service.is_some(),
            self.managed_verified,
            &envelope.authority_epoch,
            &self.epoch,
        ) {
            let e = self.envelope(json!({"kind":"result", "command_id":requested_id, "ok":false, "message":"Reconnect to the current host before editing"}));
            self.send(id, e);
            return;
        }
        let Ok(command) = serde_json::from_value::<WorldCommand>(envelope.body) else {
            let snapshot = self.model.snapshot();
            let error = self.envelope(
                json!({"kind":"result", "command_id":requested_id, "ok":false,
                "message":"Invalid edit payload", "snapshot":snapshot}),
            );
            self.send(id, error);
            return;
        };
        if command.command_id().len() > 80 || command.command_id().is_empty() {
            return;
        }
        self.dispatch_command(id, command, false);
    }
    fn handle_network(&mut self, value: Value) {
        match value["type"].as_str().unwrap_or("") {
            "ready" => {
                self.transport_ready = true;
                if self.service.is_some() && !self.host {self.managed_verified=false;}
                if self.automatic_role
                    && let Some(peer) = value["self_peer"].as_str()
                {
                    self.host = peer == self.host_peer;
                    self.peer = peer.into();
                    if self.host && self.epoch.is_empty() {
                        self.epoch = Uuid::new_v4().to_string();
                        self.synced = true;
                    }
                }
                self.clear_remote_presence();
                if let Some(peers) = value["peers"].as_array() {
                    for peer in peers {
                        if let (Some(id), Some(epoch)) =
                            (peer["peer"].as_str(), peer["publisherEpoch"].as_str())
                            && id != self.peer
                        {
                            self.remote_epochs.insert(id.into(), epoch.into());
                        }
                    }
                }
                self.status("KokoSync connected");
                self.publish_state();
                if !self.host {
                    self.request_snapshot();
                }
            }
            "error" => {
                self.transport_ready = false;
                self.clear_remote_presence();
                if !self.host {
                    self.synced = false;
                    self.pending.clear();
                }
                self.status(
                    value["message"]
                        .as_str()
                        .unwrap_or("Transport failed; reconnect"),
                );
            }
            "peer_left" => {
                if let Some(peer) = value["peer"].as_str() {
                    self.managed_peers.remove(peer);
                }
                if let (Some(peer), Some(epoch)) =
                    (value["peer"].as_str(), value["publisher_epoch"].as_str())
                    && state_rules::epoch_matches(&self.remote_epochs, peer, epoch)
                {
                    self.remote_epochs.remove(peer);
                    let id = format!("{peer}:{epoch}");
                    self.previews.forget(&id);
                    self.remote_rays.remove(&id);
                    self.rays_dirty = true;
                    self.remote_seen.remove(&id);
                    self.model.remove_participant(&id);
                    self.chat_last_sent.remove(&id);
                    self.edit_sessions.forget(&id);
                    if peer == self.host_peer && !self.host {
                        self.synced = false;
                        self.pending.clear();
                        self.deferred_results.clear();
                        self.status("Host disconnected. Editing paused.");
                    }
                }
            }
            "peer_joined" => {
                if let Some(peer) = value["peer"].as_str() {
                    self.managed_peers.remove(peer);
                }
                if let (Some(peer), Some(epoch)) =
                    (value["peer"].as_str(), value["publisher_epoch"].as_str())
                {
                    if let Some(old) = self.remote_epochs.insert(peer.into(), epoch.into()) {
                        self.remote_rays.remove(&format!("{peer}:{old}"));
                        self.rays_dirty = true;
                        self.previews.forget(&format!("{peer}:{old}"));
                        self.model.remove_participant(&format!("{peer}:{old}"));
                        self.remote_seen.remove(&format!("{peer}:{old}"));
                        self.chat_last_sent.remove(&format!("{peer}:{old}"));
                    }
                    if peer == self.host_peer && !self.host {
                        self.synced = false;
                        self.epoch.clear();
                        self.request_snapshot();
                    }
                }
            }
            "pose" => {
                let (Some(peer), Some(epoch)) =
                    (value["peer"].as_str(), value["publisher_epoch"].as_str())
                else {
                    return;
                };
                if !state_rules::epoch_matches(&self.remote_epochs, peer, epoch) {
                    return;
                }
                let Ok(e) = serde_json::from_value::<Envelope>(value["body"].clone()) else {
                    return;
                };
                if e.protocol_version != VERSION
                    || e.session_id != self.session
                    || e.body["kind"] != "pose"
                {
                    return;
                }
                let (Some(name), Ok(pose)) = (
                    e.body["name"].as_str(),
                    serde_json::from_value::<AvatarPose>(e.body["pose"].clone()),
                ) else {
                    return;
                };
                let id = format!("{peer}:{epoch}");
                let ray = serde_json::from_value::<InteractionRay>(e.body["ray"].clone())
                    .ok()
                    .filter(|r| {
                        r.origin
                            .iter()
                            .chain(&r.point)
                            .all(|v| v.is_finite() && v.abs() < 1010.0)
                            && (0..3)
                                .map(|i| (r.point[i] - r.origin[i]).powi(2))
                                .sum::<f64>()
                                <= 36.01
                            && (0..3)
                                .map(|i| (r.origin[i] - pose.position[i]).powi(2))
                                .sum::<f64>()
                                < 4.0
                    });
                match ray {
                    Some(ray) => {
                        if self.remote_rays.get(&id) != Some(&ray) {
                            self.remote_rays.insert(id.clone(), ray);
                            self.rays_dirty = true;
                        }
                    }
                    None => {
                        self.rays_dirty |= self.remote_rays.remove(&id).is_some();
                    }
                }
                if let Ok(sequence) = e.sequence.parse::<u64>() {
                    let preview =
                        serde_json::from_value::<ObjectPreview>(e.body["preview"].clone())
                            .ok()
                            .filter(|preview| {
                                self.synced
                                    && e.authority_epoch == self.epoch
                                    && self.model.accepts_preview(preview)
                                    && (!self.host || self.service.is_none() || self.managed_peers.contains_key(peer))
                            });
                    self.previews
                        .receive(id.clone(), sequence, preview, std::time::Instant::now());
                }
                if self
                    .model
                    .update_participant(ParticipantView {
                        id: id.clone(),
                        name: name.into(),
                        pose,
                        avatar_texture: e.body["avatar_texture"].as_str().map(str::to_owned),
                    })
                    .is_ok()
                {
                    self.remote_seen.insert(id, std::time::Instant::now());
                }
            }
            "message" => {
                let Some(peer) = value["peer"].as_str() else {
                    return;
                };
                let Ok(e) = serde_json::from_value::<Envelope>(value["body"].clone()) else {
                    return;
                };
                if e.protocol_version != VERSION || e.session_id != self.session {
                    return;
                }
                if e.body["kind"].as_str().is_some_and(|kind|kind.starts_with("script_graph")) {
                    if (self.host || peer == self.host_peer) && e.authority_epoch == self.epoch { self.graph_document_message(Origin::Peer(peer.into()), &e.body); }
                    return;
                }
                if e.body["kind"].as_str().is_some_and(|kind|kind.starts_with("script_document")) {
                    if (self.host || peer == self.host_peer) && e.authority_epoch == self.epoch { self.script_document_message(Origin::Peer(peer.into()), &e.body); }
                    return;
                }
                if e.body["kind"] == "clock_ping" || e.body["kind"] == "clock_pong" {
                    if (self.host || peer == self.host_peer) && e.authority_epoch == self.epoch {
                        self.clock_message(Origin::Peer(peer.into()), &e.body);
                    }
                    return;
                }
                if e.body["kind"]
                    .as_str()
                    .is_some_and(|k| k.starts_with("asset_"))
                {
                    if (self.host || peer == self.host_peer) && e.authority_epoch == self.epoch {
                        self.asset_message(Origin::Peer(peer.into()), &e.body);
                    }
                    return;
                }
                if self.host {
                    if e.body["kind"] == "snapshot_request" {
                        let snapshot = self.model.snapshot();
                        self.network(Some(peer), json!({"kind":"component_snapshot", "snapshot":REGISTRY.encode_world(&snapshot),"script_statuses":self.model.script_statuses(),"chat":self.model.chat_messages()}));
                        self.network(
                            Some(peer),
                            json!({"kind":"edit_sessions","sessions":self.edit_sessions.views()}),
                        );
                    } else if e.body["kind"] == "chat_send" && e.authority_epoch == self.epoch {
                        if let (Some(publisher_epoch),Some(text)) =
                            (value["publisher_epoch"].as_str(),e.body["text"].as_str())
                            && state_rules::epoch_matches(&self.remote_epochs, peer, publisher_epoch) {
                                self.submit_chat(&format!("{peer}:{publisher_epoch}"),text,Origin::Peer(peer.into()));
                        }
                    } else if e.body["kind"] == "edit_session" && e.authority_epoch == self.epoch {
                        if let Ok(input) = serde_json::from_value(e.body["request"].clone()) {
                            let owner = format!(
                                "{}:{}",
                                peer,
                                value["publisher_epoch"].as_str().unwrap_or("")
                            );
                            self.apply_edit_session(&owner, input, Origin::Peer(peer.into()));
                        }
                    } else if (e.body["kind"] == "edit"
                        || e.body["kind"] == "structure"
                        || e.body["kind"] == "transform"
                        || e.body["kind"] == "playback"
                        || e.body["kind"] == "script")
                        && e.authority_epoch == self.epoch
                        && let Ok(command) = serde_json::from_value::<WorldCommand>(e.body)
                    {
                        if command.command_id().len() > 80 || command.command_id().is_empty() {
                            return;
                        }
                        let requester = format!(
                            "{}:{}",
                            peer,
                            value["publisher_epoch"].as_str().unwrap_or("")
                        );
                        self.queue_command(&requester, command, Origin::Peer(peer.into()));
                    }
                } else if peer == self.host_peer {
                    let kind = e.body["kind"].as_str().unwrap_or("");
                    if kind == "edit_sessions" && e.authority_epoch == self.epoch {
                        if let Ok(sessions) = serde_json::from_value(e.body["sessions"].clone()) {
                            self.remote_edit_sessions = sessions;
                        }
                        return;
                    }
                    if kind == "component_snapshot" {
                        if !self.epoch.is_empty() && e.authority_epoch != self.epoch {
                            return;
                        }
                        let Ok(snapshot) =
                            serde_json::from_value::<ReplicatedWorld>(e.body["snapshot"].clone())
                                .map_err(|e| e.to_string())
                                .and_then(|s| REGISTRY.decode_world(s))
                        else {
                            return;
                        };
                        let Ok(revision) = snapshot.world_revision.parse::<u64>() else {
                            return;
                        };
                        let current = self.model.snapshot().world_revision.parse::<u64>().unwrap();
                        if self.synced && revision < current {
                            return;
                        }
                        let Ok(chat) = serde_json::from_value::<Vec<SessionChatMessage>>(e.body["chat"].clone()) else { return; };
                        if self.model.restore(snapshot).is_ok() && self.model.replace_chat(chat).is_ok() {
                            self.remote_script_status =
                                serde_json::from_value(e.body["script_statuses"].clone())
                                    .unwrap_or_default();
                            self.epoch = e.authority_epoch;
                            self.synced = true;
                            self.publish_state();
                            self.flush_results();
                        }
                    } else if kind == "chat_message" && self.synced && e.authority_epoch == self.epoch {
                        if let Ok(message) = serde_json::from_value::<SessionChatMessage>(e.body["message"].clone())
                            && self.model.append_chat(message).unwrap_or(false) {
                                self.publish_chat();
                        }
                    } else if kind == "chat_error" && e.authority_epoch == self.epoch {
                        self.ui(e.body);
                    } else if kind == "camera_capture" && self.synced && e.authority_epoch == self.epoch {
                        self.ui(e.body);
                    } else if kind == "script_statuses"
                        && self.synced
                        && e.authority_epoch == self.epoch
                    {
                        if let Ok(statuses) = serde_json::from_value(e.body["statuses"].clone()) {
                            self.remote_script_status = statuses;
                        }
                    } else if kind == "component_commit"
                        && self.synced
                        && e.authority_epoch == self.epoch
                    {
                        let Ok(commit) =
                            serde_json::from_value::<ReplicationCommit>(e.body["commit"].clone())
                                .map_err(|e| e.to_string())
                                .and_then(|c| REGISTRY.decode_commit(c))
                        else {
                            self.synced = false;
                            self.status("Invalid component update. Resynchronizing…");
                            self.request_snapshot();
                            return;
                        };
                        let current = self.model.snapshot().world_revision.parse::<u64>().unwrap();
                        if commit
                            .world_revision
                            .parse::<u64>()
                            .is_ok_and(|r| r <= current)
                        {
                            return;
                        }
                        if self.model.apply_commit(commit).is_err() {
                            self.synced = false;
                            self.status("Missing or invalid update. Resynchronizing…");
                            self.request_snapshot();
                        } else {
                            self.publish_state();
                            self.flush_results();
                        }
                    } else if kind == "result"
                        && e.authority_epoch == self.epoch
                        && let Some(command) = e.body["command_id"].as_str()
                        && self.pending.contains_key(command)
                    {
                        if let Ok(snapshot) =
                            serde_json::from_value::<ReplicatedWorld>(e.body["snapshot"].clone())
                                .map_err(|e| e.to_string())
                                .and_then(|s| REGISTRY.decode_world(s))
                        {
                            let current =
                                self.model.snapshot().world_revision.parse::<u64>().unwrap();
                            if snapshot
                                .world_revision
                                .parse::<u64>()
                                .is_ok_and(|r| r > current)
                                && self.model.restore(snapshot).is_ok()
                            {
                                self.publish_state();
                            }
                        }
                        self.deferred_results.insert(command.to_string(), e.body);
                        self.flush_results();
                    }
                }
            }
            _ => {}
        }
    }
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<_> = std::env::args().collect();
    let _shutdown = console::initialize(&args)?;
    let result = run().await;
    if let Err(error) = &result { eprintln!("Engine stopped with an error: {error}"); }
    result
}

async fn run() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<_> = std::env::args().collect();
    // Do not register Tokio's Windows handler over our console-close handler.
    let native_console = cfg!(windows) && args.iter().any(|arg| arg == "--console");
    let arg = |key: &str, default: &str| {
        args.windows(2)
            .find(|w| w[0] == key)
            .map(|w| w[1].clone())
            .unwrap_or(default.into())
    };
    let server = arg("--server", "");
    let managed = !server.is_empty();
    let role = if managed {
        "lobby".into()
    } else {
        arg("--role", "host")
    };
    let host = role == "host";
    let ui_port = arg("--port", "47000");
    let transport_port = arg("--transport-port", "47001");
    let ui = TcpListener::bind(format!("127.0.0.1:{ui_port}")).await?;
    let transport = TcpListener::bind(format!("127.0.0.1:{transport_port}")).await?;
    let clock = media_clock::ClockSync::new();
    let mut model = WorldModel::new();
    model.set_media_time(clock.now());
    let load = arg("--load", "");
    let save = arg("--save", "");
    let save_path = (!managed && !save.is_empty()).then(|| std::path::PathBuf::from(&save));
    if !load.is_empty() {
        model.restore(persistence::read_snapshot(std::path::Path::new(&load))?)?;
    } else if host
        && let Some(path) = &save_path
        && (path.exists() || persistence::backup_path(path).exists())
    {
        model.restore(persistence::load_checkpoint(path)?)?;
        eprintln!("Restored world from {}", path.display());
    }
    // Auto-role clients must wait for the relay's decision: a guest can join
    // even if an unrelated checkpoint in its own installation is unreadable.
    let mut auto_checkpoint = if role == "auto" && load.is_empty() {
        save_path.clone()
    } else {
        None
    };
    let mut persistence = persistence::Persistence::new(save_path);
    let asset_root =
        std::path::PathBuf::from(arg("--asset-dir", &format!(".run/assets/{ui_port}")));
    let service = if managed {
        Some(management::Service::open(
            server,
            std::path::PathBuf::from(arg("--profile", ".run/profiles/default/profile.dat")),
            std::path::PathBuf::from(arg("--data-dir", ".run/managed/default")),
            asset_root.clone(),
        )?)
    } else {
        None
    };
    let service_user = service
        .as_ref()
        .and_then(|s| s.profile.try_lock().ok().map(|p| p.user.clone()))
        .unwrap_or(Value::Null);
    let mut engine = Engine {
        service,
        service_user,
        active_session: None,
        active_project: None,
        service_generation: 0,
        service_jobs: 0,
        transport_ready: false,
        managed_verified: false,
        managed_peers: HashMap::new(),
        managed_aliases: HashMap::new(),
        managed_placed: HashMap::new(),
        clock,
        assets: assets::Assets::new(asset_root)?,
        local_ray: None,
        remote_rays: HashMap::new(),
        rays_dirty: false,
        grab_owner: None,
        grab_command: None,
        last_grab: None,
        previews: previews::Previews::default(),
        model,
        edit_sessions: Default::default(),
        documents: Default::default(),
        graph_documents: Default::default(),
        remote_edit_sessions: Vec::new(),
        last_edit_sessions: Value::Null,
        host,
        automatic_role: role == "auto",
        host_peer: arg("--host-peer", "host"),
        session: if managed {
            "lobby".into()
        } else {
            arg("--session", "demo")
        },
        epoch: if host {
            Uuid::new_v4().to_string()
        } else {
            String::new()
        },
        sequence: 0,
        synced: host,
        adapter: None,
        clients: HashMap::new(),
        pending: HashMap::new(),
        deferred_results: HashMap::new(),
        tickets: HashMap::new(),
        inflight: HashMap::new(),
        peer: arg("--peer", if host { "host" } else { "guest" }),
        input_owner: None,
        last_tick: std::time::Instant::now(),
        pose_sequence: 0,
        remote_epochs: HashMap::new(),
        remote_seen: HashMap::new(),
        chat_last_sent: HashMap::new(),
        outcomes: HashMap::new(),
        order: VecDeque::new(),
        last_script_status: Value::Null,
        last_drive_frame: None,
        remote_script_status: Vec::new(),
    };
    engine.model.update_participant(ParticipantView {
        avatar_texture: None,
        id: "local".into(),
        name: arg("--name", if host { "Host" } else { "Guest" }),
        pose: AvatarPose {
            position: if host {
                [-1.8, 0.0, 3.0]
            } else {
                [1.8, 0.0, 3.0]
            },
            yaw: 0.0,
            pitch: 0.0,
        },
    })?;
    engine.model.tick();
    engine.model.enable_local_player("local")?;
    engine.tick();
    let (events, mut rx) = mpsc::channel(256);
    let mut next_id = 0;
    let mut managed_child: Option<tokio::process::Child> = None;
    let mut heartbeat = tokio::time::interval(Duration::from_secs(5));
    let adapter_path = arg("--adapter", ".tools/kokosync-adapter.exe");
    eprintln!(
        "tukurium {} | UI 127.0.0.1:{} | adapter 127.0.0.1:{}",
        role,
        ui_port,
        transport_port
    );
    let mut retry = tokio::time::interval(Duration::from_secs(2));
    let mut simulation = tokio::time::interval(Duration::from_millis(16));
    let mut poses = tokio::time::interval(Duration::from_millis(50));
    let mut autosave = tokio::time::interval(Duration::from_secs(2));
    autosave.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    poses.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    simulation.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    loop {
        tokio::select! {
            _ = heartbeat.tick(), if managed => {
                if let Some(active)=engine.active_session.clone() {
                    if engine.host {
                        engine.start_service_job(0,String::new(),"heartbeat".into(),json!({"action":"heartbeat","session_id":active["session"]["id"],"ready":engine.transport_ready}),&events);
                    } else if engine.adapter.is_some() {
                        let target=engine.host_peer.clone();engine.network(Some(&target),json!({"kind":"service_identity","ticket":active["ticket"]}));
                    }
                }
            },
            _ = tokio::signal::ctrl_c(), if !native_console => break,
            _ = console::close_requested() => break,
            _ = autosave.tick() => {
                if let Err(error) = persistence.poll().await {
                    eprintln!("World autosave failed: {error}");
                    engine.status(&format!("World autosave failed: {error}"));
                }
                if engine.host {
                    persistence.schedule_with(engine.model.world_revision(), || {
                        engine.model.snapshot()
                    });
                }
            },
            _ = simulation.tick() => engine.tick(),
            _ = poses.tick() => engine.send_pose(),
            accepted = ui.accept() => { let (stream, _) = accepted?; if engine.clients.len() < 32 { next_id += 1; tokio::spawn(connection(stream, next_id, false, events.clone())); } },
            accepted = transport.accept() => { let (stream, _) = accepted?; if engine.adapter.is_none() { next_id += 1; tokio::spawn(connection(stream, next_id, true, events.clone())); } },
            _ = retry.tick() => {
                engine.expire_assets();
                engine.clock.expire();
                // Expire only the requests whose results were lost:
                // each affected client gets an explicit failure for its
                // own edit, and unrelated pending edits keep waiting.
                // The world itself is still in sync (commits keep
                // flowing), so this no longer forces a full resync.
                // A result that arrives late is ignored because its
                // pending entry is gone.
                for command in state_rules::expired_pending(engine.pending.iter().map(|(command, (_, time, _))| (command.clone(), time.elapsed()))) {
                    let Some((id, _, requested_id)) = engine.pending.remove(&command) else { continue };
                    engine.deferred_results.remove(&command);
                    engine.reply(Origin::Local(id), json!({"kind":"result","command_id":requested_id,"ok":false,"message":"Edit result timed out; check current values before retrying."}));
                    engine.status("An edit result timed out and was failed; other edits are unaffected.");
                }
                if !engine.host && !engine.synced && engine.adapter.is_some() {engine.request_snapshot();}
                let stale:Vec<_> = engine.remote_seen.iter().filter(|(_,time)| state_rules::peer_stale(time.elapsed())).map(|(id,_)| id.clone()).collect();
                for id in stale { engine.remote_seen.remove(&id); engine.model.remove_participant(&id); engine.chat_last_sent.remove(&id); engine.remote_rays.remove(&id); engine.rays_dirty=true; }
                // Placement tokens expire server-side after 60s; remembering them
                // longer only needs a margin for clock skew, so the set stays bounded.
                engine.managed_placed.retain(|_, placed| placed.elapsed() < Duration::from_secs(120));
            },
            event = rx.recv() => match event {
                Some(Event::Connected(id, adapter, out)) => {
                    if adapter && engine.adapter.is_some() { continue; }
                    engine.clients.insert(id, out);
                    if adapter { engine.adapter = Some(id); } else {
                        let state = engine.state(); let e = engine.envelope(state); engine.send(id, e);
                        if managed {let state=engine.service_state();let e=engine.envelope(state);engine.send(id,e);}
                    }
                },
                Some(Event::Message(id, value)) => {
                    if !engine.clients.contains_key(&id) { continue; }
                    if Some(id) == engine.adapter {
                        if managed && value["type"]=="message" && value["body"]["session_id"]==engine.session {
                            let body=&value["body"]["body"];
                            if body["kind"]=="service_verified" && !engine.host && value["peer"]==engine.host_peer && body["user_id"]==engine.service_user["id"] {
                                engine.managed_verified=true;engine.publish_state();continue;
                            }
                            if body["kind"]=="service_identity" && engine.host {
                                if let (Some(peer),Some(epoch),Some(ticket))=(value["peer"].as_str(),value["publisher_epoch"].as_str(),body["ticket"].as_str())
                                    && engine.remote_epochs.get(peer).is_some_and(|old|old==epoch) {
                                        engine.start_service_job(0,String::new(),"verify_ticket".into(),json!({"action":"verify_ticket","session_id":engine.session,"peer":peer,"peer_epoch":epoch,"ticket":ticket}),&events);
                                }
                                continue;
                            }
                            if body["kind"]=="service_place" && engine.host {
                                if let Some(token)=body["placement"].as_str()
                                    && !engine.managed_placed.contains_key(token) {
                                        let key=token.to_string();engine.managed_placed.insert(key.clone(),std::time::Instant::now());
                                        engine.start_service_job(0,key,"resolve_placement".into(),json!({"action":"resolve_placement","placement":token}),&events);
                                }
                                continue;
                            }
                        }
                        if value["type"] == "ready"
                            && let Some(peer) = value["self_peer"].as_str()
                            && let Some(path) = auto_checkpoint.take()
                            && peer == engine.host_peer
                            && (path.exists() || persistence::backup_path(&path).exists())
                        {
                            engine.model.restore(persistence::load_checkpoint(&path)?)?;
                            eprintln!("Restored world from {}", path.display());
                        }
                        let ready=value["type"]=="ready";
                        engine.handle_network(value);
                        if managed && ready && !engine.host && let Some(active)=engine.active_session.clone() {
                            let target=engine.host_peer.clone();engine.network(Some(&target),json!({"kind":"service_identity","ticket":active["ticket"]}));
                        }
                    } else {
                        if managed && value["body"]["kind"]=="service" {
                            let mut body=value["body"].clone();let request=body["request_id"].as_str().unwrap_or("").to_string();let action=body["action"].as_str().unwrap_or("").to_string();
                            let prepare=(||->Result<(),String>{
                                if matches!(action.as_str(),"login"|"create_session"|"join_session"|"import_profile"|"open_project_workspace") && engine.active_session.is_some(){return Err("Leave the current session first".into());}
                                if action=="save_item" {
                                    let target:kokoverse_protocol::Address=serde_json::from_value(body["target"].clone()).map_err(|_|"Select an item")?;
                                    let object=engine.model.snapshot().objects.into_iter().find(|o|o.address==target).ok_or("Selected object no longer exists")?;
                                    body["object"]=json!(object);
                                }
                                if action=="place_item" {let active=engine.active_session.as_ref().ok_or("Join a session first")?;body["session_id"]=active["session"]["id"].clone();body["ticket"]=active["ticket"].clone();}
                                Ok(())
                            })();
                            if let Err(message)=prepare {engine.reply(Origin::Local(id),json!({"kind":"service_result","action":action,"request_id":request,"ok":false,"message":message}));}
                            else {engine.start_service_job(id,request,action,body,&events);}
                            continue;
                        }
                        let save_request = serde_json::from_value::<Envelope>(value.clone()).ok()
                            .filter(|e| e.protocol_version == VERSION && e.session_id == engine.session && e.body["kind"] == "save_world");
                        if let Some(request) = save_request {
                            engine.tick();
                            let result = if engine.host {
                                persistence.flush(engine.model.snapshot()).await
                            } else { Ok(false) };
                            let response = match result {
                                Ok(saved) => json!({"kind":"save_result","request_id":request.body["request_id"],"ok":true,"saved":saved,"world_revision":engine.model.snapshot().world_revision}),
                                Err(error) => json!({"kind":"save_result","request_id":request.body["request_id"],"ok":false,"message":error}),
                            };
                            let envelope = engine.envelope(response);
                            engine.send(id, envelope);
                        } else { engine.handle_ui(id, value); }
                    }
                },
                Some(Event::ServiceDone(id,request,operation,generation,result)) => {
                    engine.service_jobs=engine.service_jobs.saturating_sub(1);
                    if generation!=engine.service_generation {continue;}
                    let handled:Result<Value,String>=async {
                        let completion=result?;
                        match completion.effect {
                            management::Effect::Login(user)=>{engine.service_user=user;},
                            management::Effect::Join(info)=>{
                                if engine.active_session.is_some(){return Err("A session is already active".into());}
                                let service=engine.service.as_ref().unwrap();let session=info["session"]["id"].as_str().ok_or("Invalid session")?.to_string();
                                let host=info["host"]==true;let mut model=WorldModel::new();
                                let save=service.data_root.join("worlds").join(format!("{session}.json"));
                                if host {
                                    let mut snapshot=if let Some(path)=info["load_world"].as_str().filter(|p|!p.is_empty()) {persistence::load_checkpoint(std::path::Path::new(path))?}else{model.snapshot()};
                                    let uid=engine.service_user["id"].as_str().ok_or("Enter your name first")?;
                                    for o in &mut snapshot.objects{if o.item_identity.is_none(){o.item_identity=Some(kokoverse_protocol::ItemIdentity{creator_id:uid.into(),owner_id:uid.into(),source_version:None,permissions:kokoverse_protocol::ItemPermissions{modify:true,redistribute:true},editors:vec![]});}}
                                    model.restore(snapshot)?;
                                }
                                if let Some(mut old)=managed_child.take(){let _=old.kill().await;let _=old.wait().await;}
                                engine.active_project=info["project_slug"].as_str().map(str::to_owned);
                                engine.active_session=Some(info.clone());engine.reset_managed_world(session.clone(),host,info["session"]["host_peer"].as_str().unwrap().into(),model);
                                persistence=persistence::Persistence::new(if host{Some(save)}else{None});
                                let relay=info["session"]["relay"].as_str().ok_or("Invalid relay")?;
                                let mut command=tokio::process::Command::new(&adapter_path);command.args(["--engine",&format!("127.0.0.1:{transport_port}"),"--session",&session,"--peer",info["peer"].as_str().unwrap(),"--address",relay]).kill_on_drop(true);
                                if !relay.starts_with("wss://") {command.arg("--insecure-development");}
                                #[cfg(windows)] command.creation_flags(0x08000000);
                                match command.spawn(){Ok(child)=>managed_child=Some(child),Err(e)=>{engine.active_session=None;engine.synced=false;return Err(format!("Could not start KokoSync adapter: {e}"));}}
                                engine.service_generation+=1;
                            },
                            management::Effect::Leave=>{
                                if engine.host {persistence.flush(engine.model.snapshot()).await?;}
                                if let (Some(slug), Some(service)) = (engine.active_project.take(), engine.service.as_ref()) {
                                    if let Err(error) = projects::save_world(&service.data_root, &slug, &engine.model.snapshot()) {
                                        eprintln!("Project autosave failed: {error}");
                                    }
                                }
                                if let Some(active)=engine.active_session.take() && active["host"]==true {let client=engine.service.as_ref().unwrap().client().await?;let _=client.rpc(json!({"action":"end_session","session_id":active["session"]["id"]})).await;}
                                if let Some(mut child)=managed_child.take(){let _=child.kill().await;let _=child.wait().await;}
                                if let Some(adapter)=engine.adapter.take(){engine.clients.remove(&adapter);}
                                persistence=persistence::Persistence::new(None);engine.reset_managed_world("lobby".into(),false,"host".into(),WorldModel::new());engine.service_generation+=1;
                            },
                            management::Effect::Verify{peer,epoch,user}=>{
                                if engine.remote_epochs.get(&peer).is_some_and(|current|current==&epoch){
                                    engine.managed_peers.insert(peer.clone(),user["user_id"].as_str().unwrap_or("").into());
                                    engine.managed_aliases.insert(user["user_id"].as_str().unwrap_or("").into(),serde_json::from_value(user["aliases"].clone()).unwrap_or_default());
                                    engine.network(Some(&peer),json!({"kind":"service_verified","user_id":user["user_id"]}));
                                }
                            },
                            management::Effect::Place(p)=>{
                                if !engine.host || p["session_id"]!=engine.session {return Err("Placement belongs to another session".into());}
                                let object:kokoverse_protocol::ObjectView=serde_json::from_value(p["object"].clone()).map_err(|_|"Invalid saved item")?;
                                let permissions=serde_json::from_value(p["permissions"].clone()).map_err(|_|"Invalid item permissions")?;
                                let identity=kokoverse_protocol::ItemIdentity{creator_id:object.item_identity.as_ref().map(|i|i.creator_id.clone()).unwrap_or_else(||p["user_id"].as_str().unwrap().into()),owner_id:p["user_id"].as_str().unwrap().into(),source_version:Some(p["version_id"].as_str().unwrap().into()),permissions,editors:vec![]};
                                let position=serde_json::from_value(p["position"].clone()).unwrap_or([0.,1.,0.]);engine.tick();
                                let commit=engine.model.place_library_item(object,identity,position)?;engine.network(None,json!({"kind":"component_commit","commit":REGISTRY.encode_commit(&commit)}));engine.publish_state();
                            },
                            management::Effect::None=>{},
                        }
                        if operation=="place_item" {
                            let token=completion.response["placement"].as_str().ok_or("Missing placement")?.to_string();
                            if engine.host {engine.managed_placed.insert(token.clone(),std::time::Instant::now());engine.start_service_job(id,request.clone(),"resolve_placement".into(),json!({"action":"resolve_placement","placement":token}),&events);}
                            else {let host=engine.host_peer.clone();engine.network(Some(&host),json!({"kind":"service_place","placement":token}));}
                        }
                        if operation=="save_item" && engine.host {
                            engine.tick();
                            if let (Ok(target),Some(version))=(serde_json::from_value::<kokoverse_protocol::Address>(completion.response["object"]["address"].clone()),completion.response["id"].as_str())
                                && let Ok(commit)=engine.model.set_item_source(&target,version.into()) {
                                engine.network(None,json!({"kind":"component_commit","commit":REGISTRY.encode_commit(&commit)}));engine.publish_state();
                            }
                        }
                        let mut response=completion.response;if response.get("ticket").is_some(){response.as_object_mut().unwrap().remove("ticket");}
                        Ok(response)
                    }.await;
                    if id!=0 {match handled{Ok(data)=>engine.reply(Origin::Local(id),json!({"kind":"service_result","request_id":request,"action":operation,"ok":true,"data":data})),Err(message)=>engine.reply(Origin::Local(id),json!({"kind":"service_result","request_id":request,"action":operation,"ok":false,"message":message}))};}
                    else if let Err(message)=handled {eprintln!("Managed {operation}: {message}");}
                    if matches!(operation.as_str(),"login"|"import_profile"|"create_session"|"join_session"|"leave_session"|"open_project_workspace"|"create_project"|"projects"|"project"){engine.ui(engine.service_state());engine.publish_state();}
                },
                Some(Event::Closed(id)) => {
                    engine.edit_sessions.forget(&format!("local-{id}"));
                    engine.close_asset_client(id);
                    if engine.grab_owner == Some(id) { engine.cancel_grab(); }
                    if engine.input_owner.is_some_and(|(owner, _)| owner == id) {
                        engine.input_owner = None;
                        engine.model.stop_player_input();
                    }
                    engine.previews.remove(&format!("local:{id}"));
                    engine.clients.remove(&id); engine.pending.retain(|_, (client, _, _)| *client != id);
                    if engine.adapter == Some(id) {
                        engine.transport_ready = false;
                        engine.clear_remote_presence();
                        engine.adapter = None;
                        if !engine.host { engine.synced = false; engine.epoch.clear(); engine.pending.clear(); engine.deferred_results.clear(); }
                        engine.status("KokoSync adapter disconnected");
                    }
                },
                None => break,
            },
        }
    }
    eprintln!("Stopping Engine; saving the current world...");
    if engine.host {
        persistence.flush(engine.model.snapshot()).await?;
        eprintln!("World saved.");
    }
    if let (Some(slug), Some(service)) = (engine.active_project.take(), engine.service.as_ref()) {
        if let Err(error) = projects::save_world(&service.data_root, &slug, &engine.model.snapshot()) {
            eprintln!("Project autosave failed: {error}");
        } else {
            eprintln!("Project saved.");
        }
    }
    if let Some(active) = engine.active_session.take()
        && active["host"] == true
        && let Some(service) = &engine.service
    {
        // Closing a console gives us a short OS deadline. Disk save above must
        // not depend on a remote service being reachable.
        let result = tokio::time::timeout(Duration::from_secs(1), async {
            let client = service.client().await?;
            client.rpc(json!({"action":"end_session","session_id":active["session"]["id"]})).await
        }).await;
        if !matches!(result, Ok(Ok(_))) { eprintln!("Session end notification unavailable; local world is saved."); }
    }
    if let Some(mut child) = managed_child.take() {
        let _ = child.kill().await;
        let _ = child.wait().await;
    }
    engine.ui(json!({"kind":"engine_shutdown"}));
    tokio::time::sleep(Duration::from_millis(150)).await;
    eprintln!("Engine stopped.");
    Ok(())
}

#[cfg(test)]
mod catalog_tests {
    use super::*;

    #[test]
    fn catalog_carries_the_static_schemas_and_templates() {
        let catalog = Engine::catalog();
        assert_eq!(catalog["kind"], json!("catalog"));
        assert_eq!(catalog["component_schemas"], json!(REGISTRY.schemas()));
        let templates = catalog["script_templates"].as_array().unwrap();
        assert_eq!(templates.len(), 4);
        assert_eq!(templates[0]["name"], json!("Rotator"));
        assert_eq!(
            templates[0]["source"],
            json!(kokoverse_core::scripting::ROTATOR)
        );
        assert_eq!(templates[3]["name"], json!("Countdown Camera · Nodes"));
    }
}
