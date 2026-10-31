use crate::components::*;
use bevy_ecs::prelude::*;
use kokoverse_protocol::{Address, ObjectView, Snapshot, WorldCommand, WorldCommit};
use std::collections::{HashMap, HashSet, VecDeque};

#[derive(Resource, Default)]
pub(crate) struct EntityIndex(pub HashMap<Address, Entity>);
#[derive(Resource, Default)]
pub(crate) struct WorldRevision(pub u64);
#[derive(Resource, Default, Clone, Copy)]
pub(crate) struct MediaClock(pub f64);
#[derive(Resource, Default)]
pub(crate) struct InputQueue(pub VecDeque<(u64, WorldCommand)>);
#[derive(Resource, Default)]
pub(crate) struct Authors(pub HashMap<u64, kokoverse_protocol::ItemEditor>);

pub(crate) enum Mutation {
    SetField {
        entity: Entity,
        component_id: u32,
        field: String,
        value: serde_json::Value,
    },
    SetTransform {
        entity: Entity,
        space: kokoverse_protocol::PositionSpace,
        position: [f64; 3],
        rotation: [f64; 4],
        scale: [f64; 3],
    },
    SetPlayback {
        entity: Entity,
        value: kokoverse_protocol::VideoPlayback,
    },
    SetScripts {
        entity: Entity,
        value: Vec<kokoverse_protocol::ScriptComponent>,
    },
    ScriptInteract {
        entity: Entity,
        action: kokoverse_protocol::ScriptAction,
    },
    ScriptFrame { patches: Vec<crate::scripting::FramePatch>, field_writes: Vec<crate::scripting::FieldWrite> },
    MotionFrame { patches: Vec<crate::motion::MotionPatch> },
    Insert(Box<ObjectView>),
    InsertMany(Vec<ObjectView>),
    Replace(Box<ObjectView>),
    Reparent { entity: Entity, parent: Option<Address>, local: LocalTransform },
    Delete(Address),
}

pub(crate) struct PreparedCommand {
    pub ticket: u64,
    pub mutation: Result<Mutation, String>,
}
#[derive(Resource, Default)]
pub(crate) struct Prepared(pub Option<PreparedCommand>);

pub(crate) struct AppliedCommand {
    pub ticket: u64,
    pub result: Result<Option<Address>, String>,
}
#[derive(Resource, Default)]
pub(crate) struct Applied(pub Option<AppliedCommand>);

#[derive(Resource, Default)]
pub(crate) struct ChangeSet {
    pub upserts: HashSet<Address>,
    pub removed: Vec<Address>,
}

/// The latest extracted world snapshot. Held behind an `Arc` because
/// several schedules (scripts, drives, motion, contacts) read the
/// whole snapshot every frame; replacing the extraction swaps the
/// `Arc` instead of each reader cloning the world (which includes
/// image payloads). The snapshot itself stays immutable, exactly as
/// before — readers never mutated their clones.
#[derive(Resource)]
pub(crate) struct SnapshotCache(pub std::sync::Arc<Snapshot>);

pub struct CommandOutcome {
    pub ticket: u64,
    pub result: Result<WorldCommit, String>,
    pub selected: Option<Address>,
}

#[derive(Resource, Default)]
pub(crate) struct OutputQueue(pub Vec<CommandOutcome>);

pub(crate) fn insert_object(world: &mut World, object: ObjectView) {
    let mut revisions = Revisions::default();
    for f in &object.fields {
        revisions.0.insert(
            f.id.clone(),
            f.revision.parse().expect("validated revision"),
        );
    }
    let get = |id: &str| {
        &object
            .fields
            .iter()
            .find(|f| f.id == id)
            .expect("validated field")
            .value
    };
    let slot = world
        .spawn((
            Identity(object.address.clone()),
            ObjectRoot {
                revision: object.object_revision.parse().expect("validated revision"),
                renderer: object.renderer.clone(),
                item_identity: object.item_identity.clone(),
            },
            Slot {
                name: get("name").as_str().expect("validated name").into(),
                parent: object.parent.clone(),
            },
            LocalTransform {
                translation: serde_json::from_value(get("position").clone())
                    .expect("validated position"),
                rotation: serde_json::from_value(get("rotation").clone()).expect("validated rotation"),
                scale: serde_json::from_value(get("scale").clone()).expect("validated scale"),
            },
            GlobalTransform::default(),
            revisions,
        ))
        .id();
    if let Some(shape) = object.collider {
        world.entity_mut(slot).insert(Collider(shape));
    }
    if let Some(playback) = object.playback {
        world.entity_mut(slot).insert(MediaPlayback(playback));
    }
    if let Some(panel) = object.panel.clone() {
        world.entity_mut(slot).insert(WorldPanel(panel));
    }
    if let Some(inspector) = object.inspector.clone() {
        world.entity_mut(slot).insert(InspectorView(inspector));
    }
    if let Some(creation) = object.creation.clone() {
        world.entity_mut(slot).insert(CreationView(creation));
    }
    if let Some(resources) = object.resources.clone() {
        world.entity_mut(slot).insert(ResourcesView(resources));
    }
    if let Some(script_editor) = object.script_editor.clone() {
        world.entity_mut(slot).insert(ScriptEditorView(script_editor));
    }
    if let Some(world_text) = object.world_text.clone() {
        world.entity_mut(slot).insert(WorldText(world_text));
    }
    if let Some(enabled) = object.mirror {
        world.entity_mut(slot).insert(Mirror(enabled));
    }
    if let Some(enabled) = object.camera {
        world.entity_mut(slot).insert(Camera(enabled));
    }
    if let Some(value) = object.value_number { world.entity_mut(slot).insert(ValueNumber(value)); }
    if let Some(value) = object.value_bool { world.entity_mut(slot).insert(ValueBool(value)); }
    if let Some(value) = object.value_text.clone() { world.entity_mut(slot).insert(ValueText(value)); }
    if let Some(enabled) = object.button { world.entity_mut(slot).insert(Button(enabled)); }
    if let Some(enabled) = object.contact_sensor { world.entity_mut(slot).insert(ContactSensor(enabled)); }
    if let Some(motion) = object.planar_motion.clone() { world.entity_mut(slot).insert(PlanarMotion(motion)); }
    world
        .entity_mut(slot)
        .insert(ScriptComponents(object.scripts.clone()));
    let renderer = object.renderer.as_ref().map(|address| {
        world.spawn((
            Identity(address.clone()),
            MeshRenderer {
                host: object.address.clone(),
                color: serde_json::from_value(get("color").clone()).expect("validated color"),
                visual: object.visual,
            },
        )).id()
    });
    let mut index = world.resource_mut::<EntityIndex>();
    index.0.insert(object.address, slot);
    if let (Some(address), Some(renderer)) = (object.renderer, renderer) { index.0.insert(address, renderer); }
}

pub(crate) fn remove_object(world: &mut World, address: &Address) {
    let entity = world.resource::<EntityIndex>().0[address];
    let renderer = world
        .get::<ObjectRoot>(entity)
        .expect("validated root")
        .renderer
        .clone();
    if let Some(renderer) = &renderer {
        let renderer_entity = world.resource::<EntityIndex>().0[renderer];
        world.despawn(renderer_entity);
    }
    world.despawn(entity);
    let mut index = world.resource_mut::<EntityIndex>();
    if let Some(renderer) = &renderer { index.0.remove(renderer); }
    index.0.remove(address);
}
