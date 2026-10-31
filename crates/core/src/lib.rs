//! A renderer-independent ECS world with a scheduled command/transform/output pipeline.
pub mod asset_validation;
mod collision;
mod contacts;
mod drives;
mod components;
pub mod edit_sessions;
mod grabbing;
mod hierarchy;
mod references;
pub mod locomotion;
mod motion;
pub mod panels;
pub mod presence;
pub mod session_chat;
pub mod replication;
mod resources;
pub mod scripting;
pub mod script_documents;
pub mod graph_documents;
pub mod systems;

use bevy_ecs::prelude::*;
pub use components::*;
use kokoverse_protocol::{Address, Field, ObjectView, Snapshot, WorldCommand, WorldCommit};
pub use resources::CommandOutcome;
use resources::*;
use serde_json::{Value, json};
use std::collections::HashSet;
use std::sync::{Mutex, OnceLock};
use uuid::Uuid;

pub const MAX_OBJECTS: usize = 128;
pub(crate) const MAX_IMAGE_BYTES: usize = 192 * 1024;
pub(crate) const MAX_IMAGE_WORLD: usize = 512 * 1024;
const MAX_QUEUED: usize = 256;

pub struct WorldModel {
    world: World,
    schedule: Schedule,
    next_ticket: u64,
    simulation: Schedule,
    accumulator: f64,
    script_schedule: Schedule,
    motion_schedule: Schedule,
    drive_schedule: Schedule,
    script_accumulator: f64,
    motion_accumulator: f64,
    script_authority: bool,
    panel_schedule: Schedule,
}

impl Default for WorldModel {
    fn default() -> Self {
        Self::new()
    }
}

impl WorldModel {
    fn empty() -> Self {
        let mut world = World::new();
        world.init_resource::<EntityIndex>();
        world.init_resource::<WorldRevision>();
        world.init_resource::<MediaClock>();
        world.init_resource::<InputQueue>();
        world.init_resource::<Authors>();
        world.init_resource::<Prepared>();
        world.init_resource::<Applied>();
        world.init_resource::<ChangeSet>();
        world.init_resource::<OutputQueue>();
        world.init_resource::<presence::PresenceInputs>();
        world.init_resource::<presence::PresenceIndex>();
        world.init_resource::<presence::PresenceCache>();
        world.init_resource::<session_chat::ChatHistory>();
        world.init_resource::<locomotion::LocalControl>();
        world.init_resource::<collision::CollisionWorld>();
        world.init_resource::<collision::PreviewPositions>();
        world.init_resource::<contacts::ContactRuntime>();
        world.init_resource::<motion::MotionStep>();
        world.init_resource::<grabbing::GrabState>();
        world.init_resource::<scripting::ScriptRuntime>();
        world.init_resource::<drives::DriveRuntime>();
        world.insert_resource(SnapshotCache(std::sync::Arc::new(Snapshot {
            world_revision: "0".into(),
            objects: vec![],
        })));
        let mut schedule = Schedule::default();
        schedule.add_systems(
            (
                systems::validate_commands,
                systems::apply_commands,
                presence::apply_presence,
                systems::update_transforms,
                systems::collect_changes,
                systems::extract_snapshot,
                systems::publish_changes,
                presence::extract_presence,
            )
                .chain(),
        );
        let mut simulation = Schedule::default();
        simulation.add_systems(
            (
                grabbing::update_grab,
                hierarchy::update_evaluated,
                collision::sync_colliders,
                contacts::detect,
                locomotion::simulate_character,
                presence::extract_presence,
            )
                .chain(),
        );
        let mut script_schedule = Schedule::default();
        script_schedule.add_systems(
            (
                scripting::prepare_frame,
                systems::apply_commands,
                systems::update_transforms,
                systems::collect_changes,
                systems::extract_snapshot,
                systems::publish_changes,
            )
                .chain(),
        );
        let mut drive_schedule = Schedule::default();
        drive_schedule.add_systems(drives::evaluate);
        let mut motion_schedule = Schedule::default();
        motion_schedule.add_systems((
            motion::prepare_frame,
            systems::apply_commands,
            systems::update_transforms,
            systems::collect_changes,
            systems::extract_snapshot,
            systems::publish_changes,
        ).chain());
        let mut panel_schedule = Schedule::default();
        panel_schedule.add_systems(
            (
                panels::follow_users,
                systems::update_transforms,
                systems::collect_changes,
                systems::extract_snapshot,
                systems::publish_changes,
            )
                .chain(),
        );
        Self {
            world,
            schedule,
            next_ticket: 0,
            simulation,
            accumulator: 0.0,
            script_schedule,
            motion_schedule,
            drive_schedule,
            script_accumulator: 0.0,
            motion_accumulator: 0.0,
            script_authority: false,
            panel_schedule,
        }
    }

    pub fn new() -> Self {
        let mut model = Self::empty();
        insert_object(
            &mut model.world,
            new_object(
                "Shared cube".into(),
                [0.0, 0.75, 0.0],
                [0.2, 0.65, 0.8, 1.0],
            ),
        );
        model.schedule.run(&mut model.world);
        model
    }

    /// Enqueue intent only. Nothing persistent changes until tick() runs the schedule.
    pub fn enqueue(&mut self, command: WorldCommand) -> Result<u64, String> {
        if self.world.resource::<InputQueue>().0.len() >= MAX_QUEUED {
            return Err("Editor command queue is full".into());
        }
        self.next_ticket = self
            .next_ticket
            .checked_add(1)
            .ok_or("Command tickets exhausted")?;
        self.world
            .resource_mut::<InputQueue>()
            .0
            .push_back((self.next_ticket, command));
        Ok(self.next_ticket)
    }

    pub fn enqueue_script_interaction_as(&mut self, command: WorldCommand, requester: String) -> Result<u64, String> {
        if !matches!(&command, WorldCommand::Script { command } if matches!(command.action, kokoverse_protocol::ScriptAction::Interact | kokoverse_protocol::ScriptAction::Press | kokoverse_protocol::ScriptAction::Release)) {
            return Err("Expected a script interaction".into());
        }
        let ticket = self.enqueue(command)?;
        self.world.resource_mut::<scripting::ScriptRuntime>().actors.insert(ticket, requester);
        Ok(ticket)
    }

    pub fn take_camera_captures(&mut self) -> Vec<scripting::CameraCapture> {
        std::mem::take(&mut self.world.resource_mut::<scripting::ScriptRuntime>().camera_captures)
    }

    /// Ordered command boundaries preserve per-field conflicts within one engine tick.
    pub fn tick(&mut self) -> Vec<CommandOutcome> {
        let count = self.world.resource::<InputQueue>().0.len().clamp(1, 128);
        for _ in 0..count {
            self.schedule.run(&mut self.world);
        }
        std::mem::take(&mut self.world.resource_mut::<OutputQueue>().0)
    }

    /// Editing passes do not advance time. Character simulation has its own fixed steps.
    pub fn advance(&mut self, elapsed: std::time::Duration) -> Vec<CommandOutcome> {
        let mut outcomes = self.tick();
        if self.script_authority {
            self.script_accumulator += elapsed.as_secs_f64().min(0.25);
            let interact = !self
                .world
                .resource::<scripting::ScriptRuntime>()
                .events
                .is_empty();
            if self.script_accumulator >= 0.05 || interact {
                let dt = if self.script_accumulator >= 0.05 {
                    std::mem::take(&mut self.script_accumulator)
                } else {
                    0.0
                };
                self.world.resource_mut::<scripting::ScriptRuntime>().dt = dt;
                self.script_schedule.run(&mut self.world);
                outcomes.extend(std::mem::take(
                    &mut self.world.resource_mut::<OutputQueue>().0,
                ));
            }
            self.motion_accumulator += elapsed.as_secs_f64().min(0.25);
            while self.motion_accumulator + 1e-9 >= motion::STEP {
                self.world.resource_mut::<motion::MotionStep>().0 = motion::STEP;
                self.motion_schedule.run(&mut self.world);
                outcomes.extend(std::mem::take(&mut self.world.resource_mut::<OutputQueue>().0));
                self.motion_accumulator -= motion::STEP;
            }
            self.panel_schedule.run(&mut self.world);
            outcomes.extend(std::mem::take(
                &mut self.world.resource_mut::<OutputQueue>().0,
            ));
        }
        self.drive_schedule.run(&mut self.world);
        self.accumulator += elapsed.as_secs_f64().min(0.25);
        while self.accumulator + 1e-9 >= locomotion::FIXED_STEP {
            self.simulation.run(&mut self.world);
            self.accumulator -= locomotion::FIXED_STEP;
        }
        outcomes
    }

    pub fn drive_frame(&self) -> kokoverse_protocol::DriveFrame {
        self.world.resource::<drives::DriveRuntime>().frame.clone()
    }
    pub fn set_drive_clock_ready(&mut self, ready: bool) {
        self.world.resource_mut::<drives::DriveRuntime>().ready = ready;
    }

    pub fn set_script_authority(&mut self, enabled: bool) {
        self.script_authority = enabled;
        self.world.resource_mut::<contacts::ContactRuntime>().authority = enabled;
    }
    pub fn script_statuses(&self) -> Vec<kokoverse_protocol::ScriptStatus> {
        self.world
            .resource::<scripting::ScriptRuntime>()
            .statuses
            .clone()
    }

    pub fn enable_local_player(&mut self, id: &str) -> Result<(), String> {
        locomotion::attach(&mut self.world, id)
    }

    pub fn local_player(&self) -> Option<kokoverse_protocol::ParticipantView> {
        let id = &self.world.resource::<locomotion::LocalControl>().id;
        let entity = self.world.resource::<presence::PresenceIndex>().0.get(id)?;
        Some(self.world.get::<presence::Participant>(*entity)?.0.clone())
    }

    pub fn local_motion(&self) -> Option<kokoverse_protocol::CharacterState> {
        let id = &self.world.resource::<locomotion::LocalControl>().id;
        let entity = self.world.resource::<presence::PresenceIndex>().0.get(id)?;
        Some(
            self.world
                .get::<locomotion::CharacterMotion>(*entity)?
                .0
                .clone(),
        )
    }

    pub fn set_player_input(
        &mut self,
        input: kokoverse_protocol::PlayerInput,
    ) -> Result<(), String> {
        if !locomotion::valid_input(&input) {
            return Err("Invalid player input".into());
        }
        locomotion::set_input(
            &mut self.world.resource_mut::<locomotion::LocalControl>(),
            input,
        );
        Ok(())
    }

    pub fn stop_player_input(&mut self) {
        locomotion::stop(&mut self.world.resource_mut::<locomotion::LocalControl>());
    }

    pub fn set_collision_previews(&mut self, previews: Vec<kokoverse_protocol::ObjectPreview>) {
        self.world.resource_mut::<collision::PreviewPositions>().0 = previews;
    }

    pub fn begin_grab(&mut self) -> Result<(), String> {
        // Input can arrive between simulation steps, including immediately after cancellation.
        let mut refresh = Schedule::default();
        refresh.add_systems((hierarchy::update_evaluated, collision::sync_colliders).chain());
        refresh.run(&mut self.world);
        grabbing::begin(&mut self.world)
    }

    pub fn grab_view(&self) -> Option<kokoverse_protocol::GrabView> {
        self.world
            .resource::<grabbing::GrabState>()
            .0
            .as_ref()
            .map(|held| held.view.clone())
    }

    pub fn adjust_grab_distance(&mut self, delta: f64) {
        if delta.is_finite()
            && delta.abs() <= 1.0
            && let Some(held) = self.world.resource_mut::<grabbing::GrabState>().0.as_mut()
            && !held.view.released
        {
            held.view.distance =
                (held.view.distance + delta * held.view.distance.max(1.0)).clamp(0.5, grabbing::INTERACTION_REACH);
        }
    }

    pub fn release_grab(&mut self) -> Option<(kokoverse_protocol::ObjectPreview, LocalTransform)> {
        let mut update = Schedule::default();
        update.add_systems(grabbing::update_grab);
        update.run(&mut self.world);
        let preview = {
            let grab = self.world.resource::<grabbing::GrabState>();
            let held = grab.0.as_ref()?;
            if held.view.released {
                return None;
            }
            held.view.preview.clone()
        };
        let local = hierarchy::local_from_evaluated_parent(
            &mut self.world,
            &preview.target,
            GlobalTransform {
                translation: preview.position,
                rotation: preview.rotation?,
                scale: preview.scale?,
            },
        )?;
        self.world
            .resource_mut::<grabbing::GrabState>()
            .0
            .as_mut()?
            .view
            .released = true;
        Some((preview, local))
    }

    pub fn cancel_grab(&mut self) {
        self.world.resource_mut::<grabbing::GrabState>().0 = None;
    }
    pub fn rotate_grab(&mut self, delta: [f64; 2], vertical: bool) {
        grabbing::rotate(&mut self.world, delta, vertical);
    }
    pub fn scale_grab(&mut self, factor: f64) {
        grabbing::scale(&mut self.world, factor);
    }
    pub fn align_grab(&mut self) {
        grabbing::align(&mut self.world);
    }

    pub fn interaction_ray(&self) -> Option<kokoverse_protocol::InteractionRay> {
        grabbing::interaction_ray(&self.world)
    }

    pub fn snapshot(&self) -> Snapshot {
        self.world.resource::<SnapshotCache>().0.as_ref().clone()
    }
    pub fn world_revision(&self) -> &str {
        &self.world.resource::<SnapshotCache>().0.world_revision
    }
    pub fn enqueue_as(
        &mut self,
        command: WorldCommand,
        editor: kokoverse_protocol::ItemEditor,
    ) -> Result<u64, String> {
        let ticket = self.enqueue(command)?;
        self.world
            .resource_mut::<Authors>()
            .0
            .insert(ticket, editor);
        Ok(ticket)
    }
    pub fn set_item_source(
        &mut self,
        target: &Address,
        version: String,
    ) -> Result<WorldCommit, String> {
        let snapshot = self.snapshot();
        let mut object = snapshot
            .objects
            .into_iter()
            .find(|o| &o.address == target)
            .ok_or("Item no longer exists")?;
        object
            .item_identity
            .as_mut()
            .ok_or("Item has no owner")?
            .source_version = Some(version);
        let revision = snapshot
            .world_revision
            .parse::<u64>()
            .map_err(|_| "Invalid revision")?
            .checked_add(1)
            .ok_or("Revision exhausted")?;
        object.object_revision = revision.to_string();
        let commit = WorldCommit {
            world_revision: revision.to_string(),
            upserts: vec![object],
            removed: vec![],
        };
        self.apply_commit(commit.clone())?;
        Ok(commit)
    }

    /// Import an already authorized immutable library version into a new instance.
    pub fn place_library_item(
        &mut self,
        mut object: ObjectView,
        identity: kokoverse_protocol::ItemIdentity,
        position: [f64; 3],
    ) -> Result<WorldCommit, String> {
        let id = Uuid::new_v4().to_string();
        let source_id = object.address.instance_id.clone();
        object.address.instance_id = id.clone();
        if let Some(renderer) = &mut object.renderer { renderer.instance_id = id.clone(); }
        object.object_revision = "0".into();
        object.item_identity = Some(identity);
        object.world_position = position;
        for field in &mut object.fields {
            if field.id == "position" {
                field.value = json!(position);
            }
        }
        for script in &mut object.scripts {
            script.id = Uuid::new_v4().to_string();
            script.revision = "0".into();
            script.state.clear();
            script.clock.anchor = self.world.resource::<MediaClock>().0;
            script.clock.elapsed = 0.0;
            for value in script.parameters.values_mut() {
                if let Ok(mut reference) = serde_json::from_value::<kokoverse_protocol::TypedReference>(value.clone()) {
                    let target = match &mut reference {
                        kokoverse_protocol::TypedReference::Slot { target }
                        | kokoverse_protocol::TypedReference::Component { target }
                        | kokoverse_protocol::TypedReference::Field { target, .. } => target,
                    };
                    if target.instance_id == source_id {
                        target.instance_id = id.clone();
                        *value = serde_json::to_value(reference).unwrap();
                    }
                }
            }
        }
        for field in &mut object.fields {
            field.revision = "0".into();
        }
        if let Some(playback) = &mut object.playback {
            playback.playing = false;
            playback.position_seconds = 0.0;
            playback.anchor_seconds = self.world.resource::<MediaClock>().0;
        }
        sync_object_fields(&mut object);
        let revision = self
            .snapshot()
            .world_revision
            .parse::<u64>()
            .map_err(|_| "Invalid revision")?
            .checked_add(1)
            .ok_or("Revision exhausted")?;
        let commit = WorldCommit {
            world_revision: revision.to_string(),
            upserts: vec![object],
            removed: vec![],
        };
        self.apply_commit(commit.clone())?;
        Ok(commit)
    }
    pub fn set_media_time(&mut self, time: f64) {
        if time.is_finite() && time >= 0.0 {
            self.world.resource_mut::<MediaClock>().0 = time;
        }
    }

    pub fn accepts_preview(&self, preview: &kokoverse_protocol::ObjectPreview) -> bool {
        if preview
            .rotation
            .is_some_and(|r| validate_value("rotation", &json!(r)).is_err())
            || preview
                .scale
                .is_some_and(|s| validate_value("scale", &json!(s)).is_err())
            || preview.rotation.is_some() != preview.expected_rotation_revision.is_some()
            || preview.scale.is_some() != preview.expected_scale_revision.is_some()
        {
            return false;
        }
        preview
            .position
            .iter()
            .all(|v| v.is_finite() && v.abs() <= 1000.0)
            && self
                .world
                .resource::<SnapshotCache>()
                .0
                .objects
                .iter()
                .any(|object| {
                    object.address == preview.target
                        && object.fields.iter().any(|field| {
                            field.id == "position" && field.revision == preview.expected_revision
                        })
                        && preview.expected_rotation_revision.as_ref().is_none_or(|r| {
                            object
                                .fields
                                .iter()
                                .any(|f| f.id == "rotation" && &f.revision == r)
                        })
                        && preview.expected_scale_revision.as_ref().is_none_or(|r| {
                            object
                                .fields
                                .iter()
                                .any(|f| f.id == "scale" && &f.revision == r)
                        })
                })
    }

    pub fn update_participant(
        &mut self,
        participant: kokoverse_protocol::ParticipantView,
    ) -> Result<(), String> {
        if participant.id.is_empty()
            || participant.id.len() > 256
            || participant.name.trim().is_empty()
            || participant.name.chars().count() > 40
            || !presence::valid_pose(&participant.pose)
            || participant
                .avatar_texture
                .as_ref()
                .is_some_and(|id| !kokoverse_protocol::valid_asset_id(id))
        {
            return Err("Invalid participant pose or name".into());
        }
        let mut queue = self.world.resource_mut::<presence::PresenceInputs>();
        // Coalesce high-frequency pose inputs before the next ECS tick.
        queue.0.retain(
            |input| !matches!(input, presence::PresenceInput::Upsert(p) if p.id == participant.id),
        );
        if queue.0.len() >= 64 {
            return Err("Presence queue full".into());
        }
        queue.0.push(presence::PresenceInput::Upsert(participant));
        Ok(())
    }
    pub fn remove_participant(&mut self, id: &str) {
        let mut queue = self.world.resource_mut::<presence::PresenceInputs>();
        queue
            .0
            .retain(|input| !matches!(input, presence::PresenceInput::Upsert(p) if p.id == id));
        if queue.0.len() < 64 {
            queue.0.push(presence::PresenceInput::Remove(id.into()));
        }
    }
    pub fn participants(&self) -> Vec<kokoverse_protocol::ParticipantView> {
        self.world
            .resource::<presence::PresenceCache>()
            .participants
            .clone()
    }
    pub fn presence_revision(&self) -> u64 {
        self.world.resource::<presence::PresenceCache>().revision
    }

    pub fn append_chat(&mut self, message: kokoverse_protocol::SessionChatMessage) -> Result<bool, String> {
        let value = serde_json::to_value(&message).map_err(|error| error.to_string())?;
        let registration = crate::replication::REGISTRY.session_components.iter()
            .find(|component| component.type_id == "SessionChat")
            .ok_or("SessionChat is not registered")?;
        (registration.validate)(&value)?;
        Ok(session_chat::append(&mut self.world, message))
    }

    pub fn replace_chat(&mut self, messages: Vec<kokoverse_protocol::SessionChatMessage>) -> Result<(), String> {
        if messages.len() > session_chat::MAX_MESSAGES { return Err("Too many chat messages".into()); }
        for message in &messages {
            let value = serde_json::to_value(message).map_err(|error| error.to_string())?;
            let registration = crate::replication::REGISTRY.session_components.iter()
                .find(|component| component.type_id == "SessionChat")
                .ok_or("SessionChat is not registered")?;
            (registration.validate)(&value)?;
        }
        session_chat::replace(&mut self.world, messages);
        Ok(())
    }

    pub fn chat_messages(&self) -> Vec<kokoverse_protocol::SessionChatMessage> {
        session_chat::messages(&self.world)
    }

    /// Validate everything before touching the live ECS. Used at initial synchronization.
    pub fn restore(&mut self, snapshot: Snapshot) -> Result<(), String> {
        validate_snapshot(&snapshot)?;
        let mut replacement = Self::empty();
        *replacement.world.resource_mut::<MediaClock>() = *self.world.resource::<MediaClock>();
        replacement.world.resource_mut::<drives::DriveRuntime>().ready = self.world.resource::<drives::DriveRuntime>().ready;
        for participant in self.participants() {
            replacement.update_participant(participant)?;
        }
        session_chat::replace(&mut replacement.world,self.chat_messages());
        replacement.world.resource_mut::<WorldRevision>().0 =
            snapshot.world_revision.parse().unwrap();
        replacement.world.resource_mut::<SnapshotCache>().0 =
            std::sync::Arc::new(snapshot.clone());
        for object in snapshot.objects {
            insert_object(&mut replacement.world, object);
        }
        replacement.schedule.run(&mut replacement.world);
        let control = self.world.resource::<locomotion::LocalControl>().clone();
        if !control.id.is_empty() {
            replacement.enable_local_player(&control.id)?;
            let old_entity = self.world.resource::<presence::PresenceIndex>().0[&control.id];
            if let Some(motion) = self
                .world
                .get::<locomotion::CharacterMotion>(old_entity)
                .cloned()
            {
                let entity = replacement.world.resource::<presence::PresenceIndex>().0[&control.id];
                replacement.world.entity_mut(entity).insert(motion);
            }
            *replacement.world.resource_mut::<locomotion::LocalControl>() = control;
        }
        replacement.accumulator = self.accumulator;
        replacement.motion_accumulator = self.motion_accumulator;
        replacement.script_authority = self.script_authority;
        *replacement.world.resource_mut::<contacts::ContactRuntime>() = self.world.resource::<contacts::ContactRuntime>().clone();
        *replacement
            .world
            .resource_mut::<collision::PreviewPositions>() =
            self.world.resource::<collision::PreviewPositions>().clone();
        *replacement.world.resource_mut::<grabbing::GrabState>() =
            self.world.resource::<grabbing::GrabState>().clone();
        *self = replacement;
        Ok(())
    }

    /// Apply validated per-object changes without rebuilding unaffected entities.
    pub fn apply_commit(&mut self, commit: WorldCommit) -> Result<(), String> {
        let next = self
            .world
            .resource::<WorldRevision>()
            .0
            .checked_add(1)
            .ok_or("World revision exhausted")?;
        if commit.world_revision.parse::<u64>().ok() != Some(next) {
            return Err("Missing world revision".into());
        }
        if !self.world.resource::<InputQueue>().0.is_empty() {
            return Err("Cannot replicate with queued authoring commands".into());
        }
        let mut candidate = self.snapshot();
        let mut seen = HashSet::new();
        for address in &commit.removed {
            if !seen.insert(address.clone())
                || !candidate.objects.iter().any(|o| &o.address == address)
            {
                return Err("Invalid removed object".into());
            }
            candidate.objects.retain(|o| &o.address != address);
        }
        for object in &commit.upserts {
            if !seen.insert(object.address.clone()) {
                return Err("Duplicate commit address".into());
            }
            candidate.objects.retain(|o| o.address != object.address);
            candidate.objects.push(object.clone());
        }
        if seen.is_empty() {
            return Err("Empty commit".into());
        }
        candidate.world_revision = commit.world_revision.clone();
        validate_snapshot(&candidate)?;
        for address in &commit.removed {
            remove_object(&mut self.world, address);
            self.world
                .resource_mut::<ChangeSet>()
                .removed
                .push(address.clone());
        }
        for object in commit.upserts {
            if self
                .world
                .resource::<EntityIndex>()
                .0
                .contains_key(&object.address)
            {
                remove_object(&mut self.world, &object.address);
            }
            insert_object(&mut self.world, object);
        }
        self.world.resource_mut::<WorldRevision>().0 = next;
        self.schedule.run(&mut self.world);
        Ok(())
    }
}

pub(crate) fn field(
    id: &str,
    _label: &str,
    _value_type: &str,
    value: Value,
    revs: &Revisions,
) -> Field {
    let (component, spec) = replication::REGISTRY
        .field_by_id(id)
        .expect("registered field");
    Field {
        component_id: component.local_id,
        id: id.into(),
        label: spec.schema.label.clone(),
        value_type: spec.schema.value_type.clone(),
        revision: revs.0.get(id).unwrap_or(&0).to_string(),
        value,
    }
}

pub(crate) fn new_object(name: String, position: [f64; 3], color: [f64; 4]) -> ObjectView {
    let id = Uuid::new_v4().to_string();
    ObjectView {
        parent: None,
        item_identity: None,
        address: Address {
            instance_id: id.clone(),
            local_id: 1,
        },
        renderer: Some(Address {
            instance_id: id,
            local_id: 2,
        }),
        object_revision: "0".into(),
        world_position: position,
        world_rotation: kokoverse_protocol::identity_rotation(),
        world_scale: kokoverse_protocol::unit_scale(),
        collider: Some(kokoverse_protocol::ColliderSpec {
            half_extents: [0.75; 3],
            solid: true,
        }),
        visual: kokoverse_protocol::Visual::Cube,
        playback: None,
        scripts: Vec::new(),
        panel: None,
        inspector: None,
        creation: None,
        resources: None,
        script_editor: None,
        world_text: None,
        mirror: None,
        camera: None,
        value_number: None,
        value_bool: None,
        value_text: None,
        button: None,
        contact_sensor: None,
        planar_motion: None,
        fields: vec![
            field("name", "Name", "string", json!(name), &Revisions::default()),
            field("parent", "Parent", "address", Value::Null, &Revisions::default()),
            field(
                "position",
                "Position",
                "vec3",
                json!(position),
                &Revisions::default(),
            ),
            field(
                "color",
                "Color",
                "color",
                json!(color),
                &Revisions::default(),
            ),
            field(
                "rotation",
                "Rotation",
                "quat",
                json!(kokoverse_protocol::identity_rotation()),
                &Revisions::default(),
            ),
            field(
                "scale",
                "Scale",
                "vec3",
                json!([1.0, 1.0, 1.0]),
                &Revisions::default(),
            ),
            field(
                "collider",
                "Collider",
                "collider",
                json!({"half_extents":[0.75,0.75,0.75],"solid":true}),
                &Revisions::default(),
            ),
            field(
                "playback",
                "Playback",
                "playback",
                Value::Null,
                &Revisions::default(),
            ),
        ],
    }
}

pub(crate) fn set_default_collider(object: &mut ObjectView) {
    let half_extents = match &object.visual {
        kokoverse_protocol::Visual::None => [0.0; 3],
        kokoverse_protocol::Visual::Cube => [0.75; 3],
        kokoverse_protocol::Visual::Primitive { shape } => shape.half_extents(),
        kokoverse_protocol::Visual::Panel => crate::panels::half_extents(
            object.panel.as_ref().map_or([720, 960], |panel| panel.size),
        ),
        kokoverse_protocol::Visual::Image { width, height, .. }
        | kokoverse_protocol::Visual::Video { width, height, .. } => {
            let ratio = *width as f64 / *height as f64;
            if ratio >= 1.0 {
                [1.0, 1.0 / ratio, 0.03]
            } else {
                [ratio, 1.0, 0.03]
            }
        }
        kokoverse_protocol::Visual::Model { half_extents, .. } => *half_extents,
    };
    object.collider = Some(kokoverse_protocol::ColliderSpec {
        half_extents,
        solid: !matches!(
            object.visual,
            kokoverse_protocol::Visual::Image { .. }
                | kokoverse_protocol::Visual::Video { .. }
                | kokoverse_protocol::Visual::Panel
        ),
    });
    sync_object_fields(object);
}

pub(crate) fn sync_object_fields(object: &mut ObjectView) {
    for (id, label, kind, value) in [
        ("parent", "Parent", "address", json!(object.parent)),
        ("rotation", "Rotation", "quat", json!(object.world_rotation)),
        ("scale", "Scale", "vec3", json!(object.world_scale)),
        ("collider", "Collider", "collider", json!(object.collider)),
        ("playback", "Playback", "playback", json!(object.playback)),
    ] {
        if let Some(f) = object.fields.iter_mut().find(|f| f.id == id) {
            f.value = value;
        } else {
            object
                .fields
                .push(field(id, label, kind, value, &Revisions::default()));
        }
    }
    panels::append_fields(object, &Revisions::default());
}

pub(crate) fn initialize_playback(object: &mut ObjectView, now: f64) {
    object.playback = matches!(object.visual, kokoverse_protocol::Visual::Video { .. }).then_some(
        kokoverse_protocol::VideoPlayback {
            playing: true,
            looping: true,
            position_seconds: 0.0,
            anchor_seconds: now,
        },
    );
}

pub(crate) fn validate_snapshot(snapshot: &Snapshot) -> Result<(), String> {
    scripting::validate_world_scripts(snapshot.objects.iter().map(|o| o.scripts.as_slice()))?;
    let revision = snapshot
        .world_revision
        .parse::<u64>()
        .map_err(|_| "Invalid world revision")?;
    if snapshot.objects.len() > MAX_OBJECTS {
        return Err("Object limit exceeded".into());
    }
    if snapshot
        .objects
        .iter()
        .filter(|o| o.panel.is_some())
        .count()
        > panels::MAX_PANELS
    {
        return Err("Panel limit exceeded".into());
    }
    let mut ids = HashSet::new();
    let mut image_bytes = 0;
    for object in &snapshot.objects {
        validate_visual(&object.visual)?;
        panels::validate_object(object)?;
        if object.mirror.is_some() && !matches!(object.visual, kokoverse_protocol::Visual::Primitive { shape: kokoverse_protocol::PrimitiveShape::Quad | kokoverse_protocol::PrimitiveShape::Mirror }) {
            return Err("Mirror requires a Quad surface".into());
        }
        if object.planar_motion.is_some() && (object.parent.is_some() || object.renderer.is_none() || object.collider.as_ref().is_none_or(|c| !c.solid)) {
            return Err("PlanarMotion needs a root Slot with a renderer and solid Collider".into());
        }
        if let kokoverse_protocol::Visual::Image {
            data_url,
            width,
            height,
        } = &object.visual
        {
            image_bytes += data_url.len();
            if *width == 0 || *height == 0 || image_bytes > MAX_IMAGE_WORLD {
                return Err("World image budget exceeded (512 KiB encoded)".into());
            }
        }
        if Uuid::parse_str(&object.address.instance_id).is_err()
            || object.address.local_id != 1
            || object.renderer.as_ref().is_some_and(|r| r.instance_id != object.address.instance_id || r.local_id != 2)
            || object.renderer.is_some() == matches!(object.visual, kokoverse_protocol::Visual::None)
            || !ids.insert(&object.address)
        {
            return Err("Invalid ObjectRoot ownership".into());
        }
        let object_revision = object
            .object_revision
            .parse::<u64>()
            .map_err(|_| "Invalid object revision")?;
        if object_revision > revision
            || object.fields.len()
                != replication::REGISTRY
                    .components
                    .iter()
                    .filter(|c| (c.present)(object))
                    .flat_map(|c| &c.fields)
                    .filter(|f| f.ui_order.is_some())
                    .count()
            || matches!(object.visual, kokoverse_protocol::Visual::Video { .. })
                != object.playback.is_some()
        {
            return Err("Invalid object schema".into());
        }
        let mut fields = HashSet::new();
        for f in &object.fields {
            validate_value(&f.id, &f.value)?;
            let field_revision = f
                .revision
                .parse::<u64>()
                .map_err(|_| "Invalid field revision")?;
            let (component, spec) = replication::REGISTRY.field(f.component_id, &f.id)?;
            if field_revision > object_revision
                || f.value_type != spec.schema.value_type
                || f.label != spec.schema.label
                || !(component.present)(object)
                || !fields.insert(&f.id)
            {
                return Err("Invalid field schema".into());
            }
            if (f.id == "collider"
                    && serde_json::from_value::<Option<kokoverse_protocol::ColliderSpec>>(
                        f.value.clone(),
                    )
                    .unwrap()
                        != object.collider)
                || (f.id == "playback"
                    && serde_json::from_value::<Option<kokoverse_protocol::VideoPlayback>>(
                        f.value.clone(),
                    )
                    .unwrap()
                        != object.playback)
            {
                return Err("Derived transform or collider does not match component fields".into());
            }
            if let Some(text) = &object.world_text {
                if (f.id == "world_text" && f.value.as_str() != Some(text.text.as_str()))
                    || (f.id == "world_text_color" && serde_json::from_value::<[f64; 4]>(f.value.clone()).ok() != Some(text.color)) {
                    return Err("WorldText does not match component fields".into());
                }
            }
            if (f.id == "mirror_enabled" && f.value.as_bool() != object.mirror)
                || (f.id == "camera_enabled" && f.value.as_bool() != object.camera) {
                return Err("Function component does not match its field".into());
            }
            if (f.id == "value_number" && f.value.as_f64() != object.value_number)
                || (f.id == "value_bool" && f.value.as_bool() != object.value_bool)
                || (f.id == "value_text" && f.value.as_str() != object.value_text.as_deref()) {
                return Err("ValueField does not match its field".into());
            }
            if f.id == "button_enabled" && f.value.as_bool() != object.button {
                return Err("Button does not match its field".into());
            }
            if f.id == "contact_enabled" && f.value.as_bool() != object.contact_sensor {
                return Err("ContactSensor does not match its field".into());
            }
            if let Some(motion) = &object.planar_motion {
                let expected = match f.id.as_str() {
                    "planar_velocity" => Some(json!(motion.velocity)),
                    "planar_drag" => Some(json!(motion.drag)),
                    "planar_bounce" => Some(json!(motion.bounce)),
                    "planar_bounds" => Some(json!(motion.bounds)),
                    "planar_enabled" => Some(json!(motion.enabled)),
                    _ => None,
                };
                if expected.is_some_and(|value| value != f.value) { return Err("PlanarMotion does not match its fields".into()); }
            }
        }
    }
    hierarchy::validate(snapshot)?;
    Ok(())
}

pub fn validate_visual(visual: &kokoverse_protocol::Visual) -> Result<(), String> {
    match visual {
        kokoverse_protocol::Visual::None => Ok(()),
        kokoverse_protocol::Visual::Cube
        | kokoverse_protocol::Visual::Primitive { .. }
        | kokoverse_protocol::Visual::Panel => Ok(()),
        kokoverse_protocol::Visual::Image { data_url, .. } => {
            if &validate_image(data_url)? == visual {
                Ok(())
            } else {
                Err("Invalid image dimensions".into())
            }
        }
        kokoverse_protocol::Visual::Model {
            asset_id,
            half_extents,
        } => {
            if asset_id.len() == 64
                && asset_id
                    .bytes()
                    .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
                && half_extents
                    .iter()
                    .all(|v| v.is_finite() && (0.001..=1.001).contains(v))
            {
                Ok(())
            } else {
                Err("Invalid model reference or bounds".into())
            }
        }
        kokoverse_protocol::Visual::Video {
            asset_id,
            width,
            height,
            duration_seconds,
        } => {
            if asset_id.len() == 64
                && asset_id
                    .bytes()
                    .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
                && (1..=4096).contains(width)
                && (1..=4096).contains(height)
                && duration_seconds.is_finite()
                && (0.0..=604800.0).contains(duration_seconds)
            {
                Ok(())
            } else {
                Err("Invalid video reference or dimensions".into())
            }
        }
    }
}

/// Hex SHA-256 digests (the same digest scheme asset ids use) of image
/// payloads whose full decode has already succeeded in this process.
///
/// Image payloads are immutable values: identical bytes always produce
/// the identical validation result, so revalidating the same bytes —
/// which happens for the whole world on every commit and restore — only
/// needs the header checks below. A memo miss always falls through to
/// the full decode, so the set of rejected payloads is unchanged; the
/// first sight of any payload (creation, or a commit from a peer) is
/// still fully decoded exactly once. The memo is bounded: when it fills
/// up it is cleared and payloads are simply decoded again, so only
/// performance is ever lost, never validation strength. The declared
/// format is not part of the key because the header check (which runs
/// on every call, before the memo lookup) already parses the payload
/// with the format taken from the data URL prefix, and a payload that
/// passes one format's header check cannot pass the other's.
static VERIFIED_IMAGE_DIGESTS: OnceLock<Mutex<HashSet<String>>> = OnceLock::new();
const VERIFIED_IMAGE_DIGEST_LIMIT: usize = 512;

fn verified_image_digests() -> &'static Mutex<HashSet<String>> {
    VERIFIED_IMAGE_DIGESTS.get_or_init(|| Mutex::new(HashSet::new()))
}

pub(crate) fn validate_image(data_url: &str) -> Result<kokoverse_protocol::Visual, String> {
    use base64::Engine;
    use sha2::Digest;
    let (encoded, format) = if let Some(data) = data_url.strip_prefix("data:image/png;base64,") {
        (data, image::ImageFormat::Png)
    } else if let Some(data) = data_url.strip_prefix("data:image/jpeg;base64,") {
        (data, image::ImageFormat::Jpeg)
    } else {
        return Err("Choose a PNG or JPEG image".into());
    };
    if encoded.len() > MAX_IMAGE_BYTES * 4 / 3 + 4 {
        return Err("Image is too large (192 KiB decoded)".into());
    }
    let bytes = base64::engine::general_purpose::STANDARD
        .decode(encoded)
        .map_err(|_| "Invalid image encoding")?;
    if bytes.len() > MAX_IMAGE_BYTES {
        return Err("Image is too large".into());
    }
    let reader = image::ImageReader::with_format(std::io::Cursor::new(&bytes), format);
    let (width, height) = reader
        .into_dimensions()
        .map_err(|_| "Invalid image header")?;
    if width == 0 || height == 0 || width > 2048 || height > 2048 {
        return Err("Image dimensions must be at most 2048 × 2048".into());
    }
    let digest = format!("{:x}", sha2::Sha256::digest(&bytes));
    let already_verified = verified_image_digests()
        .lock()
        .map(|set| set.contains(&digest))
        .unwrap_or(false);
    if !already_verified {
        image::load_from_memory_with_format(&bytes, format).map_err(|_| "Invalid image data")?;
        if let Ok(mut set) = verified_image_digests().lock() {
            if set.len() >= VERIFIED_IMAGE_DIGEST_LIMIT {
                set.clear();
            }
            set.insert(digest);
        }
    }
    Ok(kokoverse_protocol::Visual::Image {
        data_url: data_url.into(),
        width,
        height,
    })
}

pub(crate) fn validate_value(field: &str, value: &Value) -> Result<(), String> {
    replication::REGISTRY.validate_value(field, value)
}

#[cfg(test)]
mod tests;
