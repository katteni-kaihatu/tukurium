//! Component registration is the boundary between typed ECS data and generic replication.
//! Transport, storage and editors consume the same schemas and component records.
use crate::{components::*, resources::EntityIndex};
use bevy_ecs::prelude::*;
use kokoverse_protocol::*;
use serde_json::{Value, json};
use std::{collections::HashSet, sync::LazyLock};

type Apply = fn(&mut World, Entity, &str, Value);
type Project = fn(&ObjectView) -> Value;
type Restore = fn(&mut ObjectView, &Value) -> Result<(), String>;

pub struct FieldRegistration {
    pub schema: FieldSchema,
    pub ui_order: Option<usize>,
    pub validate: fn(&Value) -> Result<(), String>,
}
pub struct ComponentRegistration {
    pub type_id: &'static str,
    pub local_id: u32,
    pub fields: Vec<FieldRegistration>,
    pub present: fn(&ObjectView) -> bool,
    pub project: Project,
    pub restore: Restore,
    pub apply: Apply,
}
pub struct Registry {
    pub components: Vec<ComponentRegistration>,
    pub attachments: Vec<AttachmentRegistration>,
    pub session_components: Vec<SessionComponentRegistration>,
}

pub struct SessionComponentRegistration {
    pub type_id: &'static str,
    pub validate: fn(&Value) -> Result<(), String>,
}

pub struct AttachmentRegistration {
    pub type_id: &'static str,
    pub remove: fn(&mut ObjectView) -> Result<(), String>,
    pub defaults: fn() -> Value,
}

fn remove_mesh(object: &mut ObjectView) -> Result<(), String> {
    if object.panel.is_some() || object.playback.is_some() || object.mirror.is_some() || object.planar_motion.is_some() || !object.scripts.is_empty() {
        return Err("Remove dependent panel, playback, mirror, PlanarMotion, or scripts first".into());
    }
    object.renderer = None;
    object.visual = Visual::None;
    Ok(())
}

fn remove_world_text(object: &mut ObjectView) -> Result<(), String> {
    object.world_text = None;
    Ok(())
}
fn remove_mirror(object: &mut ObjectView) -> Result<(), String> {
    object.mirror = None;
    Ok(())
}
fn remove_camera(object: &mut ObjectView) -> Result<(), String> {
    object.camera = None;
    Ok(())
}
fn remove_value_number(object: &mut ObjectView) -> Result<(), String> { object.value_number = None; Ok(()) }
fn remove_value_bool(object: &mut ObjectView) -> Result<(), String> { object.value_bool = None; Ok(()) }
fn remove_value_text(object: &mut ObjectView) -> Result<(), String> { object.value_text = None; Ok(()) }
fn remove_button(object: &mut ObjectView) -> Result<(), String> { object.button = None; Ok(()) }
fn remove_contact_sensor(object: &mut ObjectView) -> Result<(), String> { object.contact_sensor = None; Ok(()) }
fn remove_planar_motion(object: &mut ObjectView) -> Result<(), String> { object.planar_motion = None; Ok(()) }
fn boolean(v: &Value) -> Result<(), String> { valid(v.is_boolean()) }
fn number(v: &Value) -> Result<(), String> {
    valid(v.as_f64().is_some_and(|n| n.is_finite() && n.abs() <= 1e9))
}
fn planar_velocity(v: &Value) -> Result<(), String> {
    vector::<3>(v, -50.0, 50.0)?;
    valid(v[1].as_f64().is_some_and(|y| y.abs() < 1e-9))
}
fn planar_drag(v: &Value) -> Result<(), String> {
    valid(v.as_f64().is_some_and(|n| n.is_finite() && (0.0..=10.0).contains(&n)))
}
fn planar_bounce(v: &Value) -> Result<(), String> {
    valid(v.as_f64().is_some_and(|n| n.is_finite() && (0.0..=1.0).contains(&n)))
}
fn planar_bounds(v: &Value) -> Result<(), String> {
    vector::<4>(v, -1000.0, 1000.0)?;
    let b: [f64; 4] = parse(v)?;
    valid(b[0] + 0.2 < b[1] && b[2] + 0.2 < b[3])
}

fn world_text(v: &Value) -> Result<(), String> {
    valid(v.as_str().is_some_and(|s| s.chars().count() <= 80 && s.len() <= 512))
}

fn field(
    id: &str,
    label: &str,
    kind: &str,
    order: Option<usize>,
    validate: fn(&Value) -> Result<(), String>,
    access: FieldAccess,
) -> FieldRegistration {
    let script_write = access == FieldAccess::Edit
        && matches!(id, "name" | "position" | "rotation" | "scale" | "color" | "world_text" | "world_text_color" | "mirror_enabled" | "camera_enabled" | "value_number" | "value_bool" | "value_text" | "planar_velocity");
    FieldRegistration {
        schema: FieldSchema {
            id: id.into(),
            label: label.into(),
            value_type: kind.into(),
            replication: ReplicationMode::Reliable,
            persistent: true,
            access,
            script_write,
            script_drive: script_write && !matches!(id, "name" | "mirror_enabled" | "camera_enabled" | "planar_velocity"),
        },
        ui_order: order,
        validate,
    }
}
fn editable(
    id: &str,
    label: &str,
    kind: &str,
    order: usize,
    validate: fn(&Value) -> Result<(), String>,
) -> FieldRegistration {
    field(id, label, kind, Some(order), validate, FieldAccess::Edit)
}
fn valid(ok: bool) -> Result<(), String> {
    if ok {
        Ok(())
    } else {
        Err("Invalid field value".into())
    }
}
fn name(v: &Value) -> Result<(), String> {
    valid(
        v.as_str()
            .is_some_and(|s| !s.trim().is_empty() && s.chars().count() <= 80),
    )
}
fn vector<const N: usize>(v: &Value, min: f64, max: f64) -> Result<(), String> {
    valid(v.as_array().is_some_and(|v| {
        v.len() == N
            && v.iter().all(|n| {
                n.as_f64()
                    .is_some_and(|n| n.is_finite() && n >= min && n <= max)
            })
    }))
}
fn position(v: &Value) -> Result<(), String> {
    vector::<3>(v, -1000.0, 1000.0)
}
fn scale(v: &Value) -> Result<(), String> {
    vector::<3>(v, 0.05, 20.0)
}
fn color(v: &Value) -> Result<(), String> {
    vector::<4>(v, 0.0, 1.0)
}
fn rotation(v: &Value) -> Result<(), String> {
    valid(
        serde_json::from_value::<[f64; 4]>(v.clone()).is_ok_and(|q| {
            q.iter().all(|v| v.is_finite())
                && (q.iter().map(|v| v * v).sum::<f64>() - 1.0).abs() < 0.0001
        }),
    )
}
fn collider(v: &Value) -> Result<(), String> {
    valid(
        v.is_null()
            || serde_json::from_value::<ColliderSpec>(v.clone()).is_ok_and(|c| {
                c.half_extents
                    .iter()
                    .all(|v| v.is_finite() && (0.001..=50.0).contains(v))
            }),
    )
}
fn playback(v: &Value) -> Result<(), String> {
    valid(
        v.is_null()
            || serde_json::from_value::<VideoPlayback>(v.clone()).is_ok_and(|p| {
                p.position_seconds.is_finite()
                    && (0.0..=1e12).contains(&p.position_seconds)
                    && p.anchor_seconds.is_finite()
                    && (0.0..=1e12).contains(&p.anchor_seconds)
            }),
    )
}
fn visual(v: &Value) -> Result<(), String> {
    crate::validate_visual(&parse::<Visual>(v)?)
}
fn global_vector(v: &Value) -> Result<(), String> {
    valid(parse::<[f64;3]>(v).is_ok_and(|v| v.iter().all(|x| x.is_finite())))
}
fn scripts(v: &Value) -> Result<(), String> {
    let scripts: Vec<ScriptComponent> = parse(v)?;
    crate::scripting::validate_world_scripts(std::iter::once(scripts.as_slice()))
}
fn panel_size(v: &Value) -> Result<(), String> {
    crate::panels::validate_field("panel_size", v)
}
fn panel_pin(v: &Value) -> Result<(), String> {
    crate::panels::validate_field("panel_pin", v)
}
fn panel_scroll(v: &Value) -> Result<(), String> {
    crate::panels::validate_field("panel_scroll", v)
}
fn inspector_scripts_open(v: &Value) -> Result<(), String> { crate::panels::validate_field("inspector_scripts_open", v) }
fn inspector_script_id(v: &Value) -> Result<(), String> { crate::panels::validate_field("inspector_script_id", v) }
fn inspector_tree(v: &Value) -> Result<(), String> { crate::panels::validate_field("inspector_tree", v) }
fn inspector_target(v: &Value) -> Result<(), String> {
    crate::panels::validate_field("inspector_target", v)
}
fn parse<T: serde::de::DeserializeOwned>(v: &Value) -> Result<T, String> {
    serde_json::from_value(v.clone()).map_err(|e| e.to_string())
}
fn ui_value(object: &ObjectView, id: &str) -> Value {
    object
        .fields
        .iter()
        .find(|f| f.id == id)
        .map(|f| f.value.clone())
        .unwrap_or(Value::Null)
}
fn renderer(world: &World, entity: Entity) -> Entity {
    world.resource::<EntityIndex>().0[world.get::<ObjectRoot>(entity).unwrap().renderer.as_ref().expect("mesh renderer")]
}
fn no_edit(_: &mut World, _: Entity, _: &str, _: Value) {
    unreachable!("Command-only field cannot be directly edited")
}

pub static REGISTRY: LazyLock<Registry> = LazyLock::new(|| Registry {
    session_components: vec![SessionComponentRegistration { type_id: "SessionChat", validate: crate::session_chat::validate_value }],
    attachments: vec![
        AttachmentRegistration { type_id: "MeshRenderer", remove: remove_mesh, defaults: || json!({"color":[0.2,0.65,0.8,1.0],"visual":{"kind":"primitive","shape":"quad"}}) },
        AttachmentRegistration { type_id: "WorldText", remove: remove_world_text, defaults: || json!({"world_text":"Text","world_text_color":[1.0,1.0,1.0,1.0]}) },
        AttachmentRegistration { type_id: "Mirror", remove: remove_mirror, defaults: || json!({"mirror_enabled":true}) },
        AttachmentRegistration { type_id: "Camera", remove: remove_camera, defaults: || json!({"camera_enabled":true}) },
        AttachmentRegistration { type_id: "ValueNumber", remove: remove_value_number, defaults: || json!({"value_number":0.0}) },
        AttachmentRegistration { type_id: "ValueBool", remove: remove_value_bool, defaults: || json!({"value_bool":false}) },
        AttachmentRegistration { type_id: "ValueText", remove: remove_value_text, defaults: || json!({"value_text":""}) },
        AttachmentRegistration { type_id: "Button", remove: remove_button, defaults: || json!({"button_enabled":true}) },
        AttachmentRegistration { type_id: "ContactSensor", remove: remove_contact_sensor, defaults: || json!({"contact_enabled":true}) },
        AttachmentRegistration { type_id: "PlanarMotion", remove: remove_planar_motion, defaults: || json!({"planar_enabled":true,"planar_velocity":[0.0,0.0,0.0],"planar_drag":0.1,"planar_bounce":0.9,"planar_bounds":[-3.0,3.0,-5.0,5.0]}) },
    ],
    components: vec![
        ComponentRegistration {
            type_id: "ItemIdentity",
            local_id: 9,
            fields: vec![field(
                "item_identity",
                "Item identity",
                "item_identity",
                None,
                |v| {
                    let i: ItemIdentity = parse(v)?;
                    if uuid::Uuid::parse_str(&i.owner_id).is_err()
                        || uuid::Uuid::parse_str(&i.creator_id).is_err()
                        || i.editors.len() > 128
                    {
                        return Err("Invalid item identity".into());
                    }
                    Ok(())
                },
                FieldAccess::Command,
            )],
            present: |o| o.item_identity.is_some(),
            project: |o| json!({"item_identity":o.item_identity}),
            restore: |o, v| {
                o.item_identity = Some(parse(&v["item_identity"])?);
                Ok(())
            },
            apply: no_edit,
        },
        ComponentRegistration {
            type_id: "Slot",
            local_id: 1,
            fields: vec![editable("name", "Name", "string", 0, name), field("parent", "Parent", "address", Some(0), inspector_target, FieldAccess::Command)],
            present: |_| true,
            project: |o| json!({"name":ui_value(o,"name"),"parent":o.parent}),
            restore: |o, v| { o.parent = parse(&v["parent"])?; Ok(()) },
            apply: |w, e, _, v| w.get_mut::<Slot>(e).unwrap().name = v.as_str().unwrap().into(),
        },
        ComponentRegistration {
            type_id: "MeshRenderer",
            local_id: 2,
            fields: vec![
                editable("color", "Color", "color", 2, color),
                field(
                    "visual",
                    "Visual",
                    "visual",
                    None,
                    visual,
                    FieldAccess::Command,
                ),
            ],
            present: |o| o.renderer.is_some(),
            project: |o| json!({"color":ui_value(o,"color"),"visual":o.visual}),
            restore: |o, v| {
                o.renderer = Some(Address { instance_id: o.address.instance_id.clone(), local_id: 2 });
                o.visual = parse(&v["visual"])?;
                Ok(())
            },
            apply: |w, e, _, v| {
                let r = renderer(w, e);
                w.get_mut::<MeshRenderer>(r).unwrap().color = parse(&v).unwrap();
            },
        },
        ComponentRegistration {
            type_id: "Transform",
            local_id: 3,
            fields: vec![
                editable("position", "Position", "vec3", 1, position),
                editable("rotation", "Rotation", "quat", 3, rotation),
                editable("scale", "Scale", "vec3", 4, scale),
                field("world_position", "World position", "vec3", None, global_vector, FieldAccess::Command),
                field("world_rotation", "World rotation", "quat", None, rotation, FieldAccess::Command),
                field("world_scale", "World scale", "vec3", None, global_vector, FieldAccess::Command),
            ],
            present: |_| true,
            project: |o| json!({"position":ui_value(o,"position"),"rotation":ui_value(o,"rotation"),"scale":ui_value(o,"scale"),"world_position":o.world_position,"world_rotation":o.world_rotation,"world_scale":o.world_scale}),
            restore: |o, v| {
                o.world_position = parse(&v["world_position"])?;
                o.world_rotation = parse(&v["world_rotation"])?;
                o.world_scale = parse(&v["world_scale"])?;
                Ok(())
            },
            apply: |w, e, id, v| {
                let mut t = w.get_mut::<LocalTransform>(e).unwrap();
                match id {
                    "position" => t.translation = parse(&v).unwrap(),
                    "rotation" => t.rotation = parse(&v).unwrap(),
                    "scale" => t.scale = parse(&v).unwrap(),
                    _ => unreachable!(),
                }
            },
        },
        ComponentRegistration {
            type_id: "Collider",
            local_id: 4,
            fields: vec![editable("collider", "Collider", "collider", 5, collider)],
            present: |_| true,
            project: |o| json!({"collider":o.collider}),
            restore: |o, v| {
                o.collider = parse(&v["collider"])?;
                Ok(())
            },
            apply: |w, e, _, v| {
                if let Some(c) = parse::<Option<ColliderSpec>>(&v).unwrap() {
                    w.entity_mut(e).insert(crate::Collider(c));
                } else {
                    w.entity_mut(e).remove::<crate::Collider>();
                }
            },
        },
        ComponentRegistration {
            type_id: "MediaPlayback",
            local_id: 5,
            fields: vec![field(
                "playback",
                "Playback",
                "playback",
                Some(6),
                playback,
                FieldAccess::Command,
            )],
            present: |_| true,
            project: |o| json!({"playback":o.playback}),
            restore: |o, v| {
                o.playback = parse(&v["playback"])?;
                Ok(())
            },
            apply: no_edit,
        },
        ComponentRegistration {
            type_id: "WorldPanel",
            local_id: 6,
            fields: vec![
                editable(
                    "panel_size",
                    "Panel resolution",
                    "panel_size",
                    7,
                    panel_size,
                ),
                editable("panel_pin", "Follow user", "panel_pin", 8, panel_pin),
            ],
            present: |o| o.panel.is_some(),
            project: |o| {
                let p = o.panel.as_ref().unwrap();
                json!({"panel_size":p.size,"panel_pin":p.attachment})
            },
            restore: |o, v| {
                o.panel = Some(kokoverse_protocol::WorldPanel {
                    size: parse(&v["panel_size"])?,
                    attachment: parse(&v["panel_pin"])?,
                });
                Ok(())
            },
            apply: |w, e, id, v| crate::panels::write_field(w, e, id, v),
        },
        ComponentRegistration {
            type_id: "InspectorView",
            local_id: 7,
            fields: vec![
                editable(
                    "inspector_target",
                    "Inspected object",
                    "address",
                    9,
                    inspector_target,
                ),
                editable("panel_scroll", "Scroll", "panel_scroll", 10, panel_scroll),
                editable("inspector_scripts_open", "Script editor", "bool", 11, inspector_scripts_open),
                editable("inspector_script_id", "Selected script", "script_id", 12, inspector_script_id),
                editable("inspector_tree", "Hierarchy", "inspector_tree", 13, inspector_tree),
            ],
            present: |o| o.inspector.is_some(),
            project: |o| {
                let i = o.inspector.as_ref().unwrap();
                json!({"inspector_target":i.target,"panel_scroll":i.scroll,"inspector_scripts_open":i.scripts_open,"inspector_script_id":i.script_id,"inspector_tree":i.tree})
            },
            restore: |o, v| {
                o.inspector = Some(kokoverse_protocol::InspectorView {
                    target: parse(&v["inspector_target"])?,
                    scroll: parse(&v["panel_scroll"])?,
                    scripts_open: parse(&v["inspector_scripts_open"])?,
                    script_id: parse(&v["inspector_script_id"])?,
                    tree: parse(&v["inspector_tree"])?,
                });
                Ok(())
            },
            apply: |w, e, id, v| crate::panels::write_field(w, e, id, v),
        },
        ComponentRegistration {
            type_id: "ScriptComponents",
            local_id: 8,
            fields: vec![field(
                "scripts",
                "Scripts",
                "scripts",
                None,
                scripts,
                FieldAccess::Command,
            )],
            present: |_| true,
            project: |o| json!({"scripts":o.scripts}),
            restore: |o, v| {
                o.scripts = parse(&v["scripts"])?;
                Ok(())
            },
            apply: no_edit,
        },
        ComponentRegistration {
            type_id: "CreationView",
            local_id: 10,
            fields: vec![editable("creation_shape", "Selected shape", "primitive_shape", 14,
                |v| parse::<PrimitiveShape>(v).map(|_| ()))],
            present: |o| o.creation.is_some(),
            project: |o| json!({"creation_shape":o.creation.as_ref().unwrap().shape}),
            restore: |o, v| {
                o.creation = Some(kokoverse_protocol::CreationView {shape: parse(&v["creation_shape"])?});
                Ok(())
            },
            apply: |w, e, _, v| w.get_mut::<crate::components::CreationView>(e).unwrap().0.shape = parse(&v).unwrap(),
        },
        ComponentRegistration {
            type_id: "ResourcesView",
            local_id: 20,
            fields: vec![
                editable("resources_target", "Selected slot", "address", 29, inspector_target),
                editable("panel_scroll", "Scroll", "panel_scroll", 30, panel_scroll),
            ],
            present: |o| o.resources.is_some(),
            project: |o| {
                let r = o.resources.as_ref().unwrap();
                json!({"resources_target":r.target,"panel_scroll":r.scroll})
            },
            restore: |o, v| {
                o.resources = Some(kokoverse_protocol::ResourcesView {
                    target: parse(&v["resources_target"])?,
                    scroll: parse(&v["panel_scroll"])?,
                });
                Ok(())
            },
            apply: |w, e, id, v| crate::panels::write_field(w, e, id, v),
        },
        ComponentRegistration {
            type_id: "ScriptEditorView",
            local_id: 21,
            fields: vec![
                editable("script_editor_target", "Script slot", "address", 31, inspector_target),
                editable("script_editor_script_id", "Selected script", "script_id", 32, inspector_script_id),
                editable("script_editor_scroll", "Scroll", "panel_scroll", 33, panel_scroll),
            ],
            present: |o| o.script_editor.is_some(),
            project: |o| {
                let s = o.script_editor.as_ref().unwrap();
                json!({"script_editor_target":s.target,"script_editor_script_id":s.script_id,"script_editor_scroll":s.scroll})
            },
            restore: |o, v| {
                o.script_editor = Some(kokoverse_protocol::ScriptEditorView {
                    target: parse(&v["script_editor_target"])?,
                    script_id: parse(&v["script_editor_script_id"])?,
                    scroll: parse(&v["script_editor_scroll"])?,
                });
                Ok(())
            },
            apply: |w, e, id, v| crate::panels::write_field(w, e, id, v),
        },
        ComponentRegistration {
            type_id: "WorldText",
            local_id: 11,
            fields: vec![
                editable("world_text", "Text", "string", 15, world_text),
                editable("world_text_color", "Text color", "color", 16, color),
            ],
            present: |o| o.world_text.is_some(),
            project: |o| {
                let text = o.world_text.as_ref().unwrap();
                json!({"world_text":text.text,"world_text_color":text.color})
            },
            restore: |o, v| {
                o.world_text = Some(kokoverse_protocol::WorldText {
                    text: parse(&v["world_text"])?,
                    color: parse(&v["world_text_color"])?,
                });
                Ok(())
            },
            apply: |w, e, id, v| {
                let mut text = w.get_mut::<crate::components::WorldText>(e).unwrap();
                match id {
                    "world_text" => text.0.text = parse(&v).unwrap(),
                    "world_text_color" => text.0.color = parse(&v).unwrap(),
                    _ => unreachable!(),
                }
            },
        },
        ComponentRegistration {
            type_id: "Mirror",
            local_id: 12,
            fields: vec![editable("mirror_enabled", "Enabled", "bool", 17, boolean)],
            present: |o| o.mirror.is_some(),
            project: |o| json!({"mirror_enabled":o.mirror.unwrap()}),
            restore: |o, v| { o.mirror = Some(parse(&v["mirror_enabled"])?); Ok(()) },
            apply: |w, e, _, v| w.get_mut::<Mirror>(e).unwrap().0 = v.as_bool().unwrap(),
        },
        ComponentRegistration {
            type_id: "Camera",
            local_id: 13,
            fields: vec![editable("camera_enabled", "Enabled", "bool", 18, boolean)],
            present: |o| o.camera.is_some(),
            project: |o| json!({"camera_enabled":o.camera.unwrap()}),
            restore: |o, v| { o.camera = Some(parse(&v["camera_enabled"])?); Ok(()) },
            apply: |w, e, _, v| w.get_mut::<Camera>(e).unwrap().0 = v.as_bool().unwrap(),
        },
        ComponentRegistration {
            type_id: "ValueNumber",
            local_id: 14,
            fields: vec![editable("value_number", "Value", "number", 19, number)],
            present: |o| o.value_number.is_some(),
            project: |o| json!({"value_number":o.value_number.unwrap()}),
            restore: |o, v| { o.value_number = Some(parse(&v["value_number"])?); Ok(()) },
            apply: |w, e, _, v| w.get_mut::<ValueNumber>(e).unwrap().0 = v.as_f64().unwrap(),
        },
        ComponentRegistration {
            type_id: "ValueBool",
            local_id: 15,
            fields: vec![editable("value_bool", "Value", "bool", 20, boolean)],
            present: |o| o.value_bool.is_some(),
            project: |o| json!({"value_bool":o.value_bool.unwrap()}),
            restore: |o, v| { o.value_bool = Some(parse(&v["value_bool"])?); Ok(()) },
            apply: |w, e, _, v| w.get_mut::<ValueBool>(e).unwrap().0 = v.as_bool().unwrap(),
        },
        ComponentRegistration {
            type_id: "ValueText",
            local_id: 16,
            fields: vec![editable("value_text", "Value", "string", 21, world_text)],
            present: |o| o.value_text.is_some(),
            project: |o| json!({"value_text":o.value_text.as_ref().unwrap()}),
            restore: |o, v| { o.value_text = Some(parse(&v["value_text"])?); Ok(()) },
            apply: |w, e, _, v| w.get_mut::<ValueText>(e).unwrap().0 = v.as_str().unwrap().into(),
        },
        ComponentRegistration {
            type_id: "Button",
            local_id: 17,
            fields: vec![editable("button_enabled", "Enabled", "bool", 22, boolean)],
            present: |o| o.button.is_some(),
            project: |o| json!({"button_enabled":o.button.unwrap()}),
            restore: |o, v| { o.button = Some(parse(&v["button_enabled"])?); Ok(()) },
            apply: |w, e, _, v| w.get_mut::<Button>(e).unwrap().0 = v.as_bool().unwrap(),
        },
        ComponentRegistration {
            type_id: "ContactSensor",
            local_id: 18,
            fields: vec![editable("contact_enabled", "Enabled", "bool", 23, boolean)],
            present: |o| o.contact_sensor.is_some(),
            project: |o| json!({"contact_enabled":o.contact_sensor.unwrap()}),
            restore: |o, v| { o.contact_sensor = Some(parse(&v["contact_enabled"])?); Ok(()) },
            apply: |w, e, _, v| w.get_mut::<ContactSensor>(e).unwrap().0 = v.as_bool().unwrap(),
        },
        ComponentRegistration {
            type_id: "PlanarMotion",
            local_id: 19,
            fields: vec![
                editable("planar_enabled", "Enabled", "bool", 24, boolean),
                editable("planar_velocity", "Velocity X/Y/Z", "vec3", 25, planar_velocity),
                editable("planar_drag", "Drag", "number", 26, planar_drag),
                editable("planar_bounce", "Bounce", "number", 27, planar_bounce),
                editable("planar_bounds", "Bounds min X / max X / min Z / max Z", "vec4", 28, planar_bounds),
            ],
            present: |o| o.planar_motion.is_some(),
            project: |o| { let m = o.planar_motion.as_ref().unwrap(); json!({"planar_enabled":m.enabled,"planar_velocity":m.velocity,"planar_drag":m.drag,"planar_bounce":m.bounce,"planar_bounds":m.bounds}) },
            restore: |o, v| { o.planar_motion = Some(PlanarMotionSpec { enabled: parse(&v["planar_enabled"])?, velocity: parse(&v["planar_velocity"])?, drag: parse(&v["planar_drag"])?, bounce: parse(&v["planar_bounce"])?, bounds: parse(&v["planar_bounds"])? }); Ok(()) },
            apply: |w, e, id, v| { let mut m = w.get_mut::<PlanarMotion>(e).unwrap(); match id { "planar_enabled" => m.0.enabled = v.as_bool().unwrap(), "planar_velocity" => m.0.velocity = parse(&v).unwrap(), "planar_drag" => m.0.drag = v.as_f64().unwrap(), "planar_bounce" => m.0.bounce = v.as_f64().unwrap(), "planar_bounds" => m.0.bounds = parse(&v).unwrap(), _ => unreachable!() } },
        },
    ],
});

impl Registry {
    pub fn change_component(&self, object: &mut ObjectView, type_id: &str, add: Option<&Value>) -> Result<(), String> {
        let attachment = self.attachments.iter().find(|a| a.type_id == type_id).ok_or("Component type cannot be attached here")?;
        let component = self.components.iter().find(|c| c.type_id == type_id).ok_or("Unregistered component type")?;
        if let Some(values) = add {
            if (component.present)(object) { return Err("Component is already attached".into()); }
            let map = values.as_object().ok_or("Component values must be an object")?;
            if map.len() != component.fields.len() { return Err("Component fields do not match the registered schema".into()); }
            for field in &component.fields {
                let value = map.get(&field.schema.id).ok_or("Missing component field")?;
                (field.validate)(value)?;
            }
            if type_id == "MeshRenderer" && !matches!(parse::<Visual>(&values["visual"])?, Visual::Cube | Visual::Primitive { .. }) {
                return Err("Only primitive renderers can be attached to an empty Slot".into());
            }
            if type_id == "WorldText" && object.panel.is_some() {
                return Err("WorldText belongs on a world Slot, not a panel surface".into());
            }
            if type_id == "Mirror" && !matches!(object.visual, Visual::Primitive { shape: PrimitiveShape::Quad | PrimitiveShape::Mirror }) {
                return Err("Mirror requires a Quad surface".into());
            }
            if type_id == "PlanarMotion" && (object.parent.is_some() || object.renderer.is_none() || object.collider.as_ref().is_none_or(|c| !c.solid)) {
                return Err("PlanarMotion needs a root Slot with a renderer and solid Collider".into());
            }
            (component.restore)(object, values)?;
            for field in component.fields.iter().filter(|f| f.ui_order.is_some()) {
                object.fields.push(Field {
                    component_id: component.local_id,
                    id: field.schema.id.clone(),
                    label: field.schema.label.clone(),
                    value_type: field.schema.value_type.clone(),
                    revision: object.object_revision.clone(),
                    value: values[&field.schema.id].clone(),
                });
            }
            object.fields.sort_by_key(|f| self.field_by_id(&f.id).unwrap().1.ui_order.unwrap());
        } else {
            if !(component.present)(object) { return Err("Component is not attached".into()); }
            (attachment.remove)(object)?;
            object.fields.retain(|f| f.component_id != component.local_id);
        }
        Ok(())
    }
    pub fn schemas(&self) -> Vec<ComponentSchema> {
        self.components
            .iter()
            .map(|c| ComponentSchema {
                type_id: c.type_id.into(),
                local_id: c.local_id,
                version: 1,
                fields: c.fields.iter().map(|f| f.schema.clone()).collect(),
                attach_defaults: self.attachments.iter().find(|a| a.type_id == c.type_id).map(|a| (a.defaults)()),
            })
            .collect()
    }
    pub fn field(
        &self,
        local_id: u32,
        id: &str,
    ) -> Result<(&ComponentRegistration, &FieldRegistration), String> {
        let c = self
            .components
            .iter()
            .find(|c| c.local_id == local_id)
            .ok_or("Unknown component address")?;
        let f = c
            .fields
            .iter()
            .find(|f| f.schema.id == id)
            .ok_or("Unknown component field")?;
        Ok((c, f))
    }
    pub fn field_by_id(
        &self,
        id: &str,
    ) -> Result<(&ComponentRegistration, &FieldRegistration), String> {
        self.components
            .iter()
            .find_map(|c| c.fields.iter().find(|f| f.schema.id == id).map(|f| (c, f)))
            .ok_or_else(|| "Unknown field".into())
    }
    pub fn validate_value(&self, id: &str, value: &Value) -> Result<(), String> {
        (self.field_by_id(id)?.1.validate)(value)
    }
    pub fn resolve<'a>(
        &self,
        snapshot: &'a Snapshot,
        address: &Address,
        id: &str,
    ) -> Result<(&'a ObjectView, &ComponentRegistration, &FieldRegistration), String> {
        let o = snapshot
            .objects
            .iter()
            .find(|o| o.address.instance_id == address.instance_id)
            .ok_or("Target no longer exists")?;
        let (c, f) = self.field(address.local_id, id)?;
        if !(c.present)(o) {
            return Err("Component no longer exists".into());
        }
        Ok((o, c, f))
    }
    pub fn script_field<'a>(
        &self,
        snapshot: &'a Snapshot,
        reference: &TypedReference,
        value: &Value,
        drive: bool,
    ) -> Result<(&'a ObjectView, u32), String> {
        let TypedReference::Field { target, field_id } = reference else {
            return Err("Expected a field reference".into());
        };
        let (object, component, field) = self.resolve(snapshot, target, field_id)?;
        if (drive && !field.schema.script_drive) || (!drive && !field.schema.script_write) {
            return Err("This field does not support script Write or Drive".into());
        }
        (field.validate)(value)?;
        Ok((object, component.local_id))
    }
    pub fn field_address(&self, object: &Address, id: &str) -> Result<Address, String> {
        Ok(Address {
            instance_id: object.instance_id.clone(),
            local_id: self.field_by_id(id)?.0.local_id,
        })
    }
    pub fn encode_object(&self, o: &ObjectView) -> ReplicatedObject {
        ReplicatedObject {
            address: o.address.clone(),
            revision: o.object_revision.clone(),
            components: self
                .components
                .iter()
                .filter(|c| (c.present)(o))
                .map(|c| {
                    let values = (c.project)(o);
                    ComponentState {
                        address: Address {
                            instance_id: o.address.instance_id.clone(),
                            local_id: c.local_id,
                        },
                        type_id: c.type_id.into(),
                        version: 1,
                        fields: c
                            .fields
                            .iter()
                            .filter(|f| f.schema.replication != ReplicationMode::Local)
                            .map(|f| ReplicatedField {
                                id: f.schema.id.clone(),
                                revision: o
                                    .fields
                                    .iter()
                                    .find(|v| v.id == f.schema.id)
                                    .map(|v| v.revision.clone())
                                    .unwrap_or_else(|| o.object_revision.clone()),
                                value: values[&f.schema.id].clone(),
                            })
                            .collect(),
                    }
                })
                .collect(),
        }
    }
    pub fn decode_object(&self, o: ReplicatedObject) -> Result<ObjectView, String> {
        if o.address.local_id != 1 || uuid::Uuid::parse_str(&o.address.instance_id).is_err() {
            return Err("Invalid object identity".into());
        }
        let mut result = crate::new_object("Object".into(), [0.0; 3], [1.0; 4]);
        result.address = o.address.clone();
        result.renderer = None;
        result.visual = Visual::None;
        result.object_revision = o.revision;
        result.fields.clear();
        let mut seen = HashSet::new();
        let mut ui = Vec::new();
        for mut component in o.components {
            if component.address.instance_id != o.address.instance_id
                || !seen.insert(component.address.local_id)
            {
                return Err("Duplicate or foreign component".into());
            }
            let c = self
                .components
                .iter()
                .find(|c| {
                    c.local_id == component.address.local_id && c.type_id == component.type_id
                })
                .ok_or("Unknown component type")?;
            // Existing panels open in the Object tab when the new optional view state is absent.
            if c.type_id == "InspectorView" && component.version == 1 && component.fields.len() == 2
                && component.fields.iter().all(|f| matches!(f.id.as_str(), "inspector_target" | "panel_scroll")) {
                for (id, value) in [("inspector_scripts_open", json!(false)), ("inspector_script_id", Value::Null)] {
                    component.fields.push(ReplicatedField {id:id.into(),revision:result.object_revision.clone(),value});
                }
            }
            if component.version != 1 || component.fields.len() != c.fields.len() {
                return Err("Unsupported component schema".into());
            }
            let mut values = serde_json::Map::new();
            for f in component.fields {
                let spec = c
                    .fields
                    .iter()
                    .find(|s| s.schema.id == f.id)
                    .ok_or("Unknown replicated field")?;
                (spec.validate)(&f.value)?;
                if values.insert(f.id.clone(), f.value.clone()).is_some() {
                    return Err("Duplicate replicated field".into());
                }
                if let Some(order) = spec.ui_order {
                    ui.push((
                        order,
                        Field {
                            component_id: c.local_id,
                            id: f.id,
                            label: spec.schema.label.clone(),
                            value_type: spec.schema.value_type.clone(),
                            revision: f.revision,
                            value: f.value,
                        },
                    ));
                } else if f.revision.parse::<u64>().ok().is_none_or(|r| {
                    result
                        .object_revision
                        .parse::<u64>()
                        .ok()
                        .is_none_or(|v| r > v)
                }) {
                    return Err("Invalid component revision".into());
                }
            }
            (c.restore)(&mut result, &Value::Object(values))?;
        }
        if self
            .components
            .iter()
            .any(|c| (c.present)(&result) != seen.contains(&c.local_id))
        {
            return Err("Missing or unexpected component".into());
        }
        ui.sort_by_key(|(order, _)| *order);
        result.fields = ui.into_iter().map(|(_, f)| f).collect();
        Ok(result)
    }
    pub fn encode_world(&self, world: &Snapshot) -> ReplicatedWorld {
        ReplicatedWorld {
            format_version: REPLICATION_VERSION,
            world_revision: world.world_revision.clone(),
            objects: world
                .objects
                .iter()
                .map(|o| self.encode_object(o))
                .collect(),
        }
    }
    pub fn decode_world(&self, world: ReplicatedWorld) -> Result<Snapshot, String> {
        if world.format_version != REPLICATION_VERSION && world.format_version != 1 {
            return Err("Unsupported world format version".into());
        }
        if world.objects.len() > crate::MAX_OBJECTS {
            return Err("Object limit exceeded".into());
        }
        let legacy = world.format_version == 1;
        let mut objects: Vec<ObjectView> = world.objects.into_iter().map(|o| self.decode_object(o)).collect::<Result<_, _>>()?;
        if legacy {
            for object in &mut objects {
                let component = match object.visual {
                    Visual::Primitive { shape: PrimitiveShape::Mirror } if object.mirror.is_none() => Some(("Mirror", json!({"mirror_enabled":true}))),
                    Visual::Primitive { shape: PrimitiveShape::Camera } if object.camera.is_none() => Some(("Camera", json!({"camera_enabled":true}))),
                    _ => None,
                };
                if let Some((type_id, values)) = component { self.change_component(object, type_id, Some(&values))?; }
            }
        }
        Ok(Snapshot {
            world_revision: world.world_revision,
            objects,
        })
    }
    pub fn encode_commit(&self, commit: &WorldCommit) -> ReplicationCommit {
        ReplicationCommit {
            format_version: REPLICATION_VERSION,
            world_revision: commit.world_revision.clone(),
            upserts: commit
                .upserts
                .iter()
                .map(|o| self.encode_object(o))
                .collect(),
            removed: commit.removed.clone(),
        }
    }
    pub fn decode_commit(&self, commit: ReplicationCommit) -> Result<WorldCommit, String> {
        if commit.format_version != REPLICATION_VERSION {
            return Err("Unsupported replication version".into());
        }
        Ok(WorldCommit {
            world_revision: commit.world_revision,
            upserts: commit
                .upserts
                .into_iter()
                .map(|o| self.decode_object(o))
                .collect::<Result<_, _>>()?,
            removed: commit.removed,
        })
    }
}

pub(crate) fn apply_field(
    world: &mut World,
    entity: Entity,
    component_id: u32,
    id: &str,
    value: Value,
) {
    let (c, _) = REGISTRY
        .field(component_id, id)
        .expect("validated registration");
    (c.apply)(world, entity, id, value);
    crate::systems::bump_field(world, entity, id);
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::WorldModel;

    #[test]
    fn registered_components_round_trip_through_json_and_reordered_records() {
        let mut model = WorldModel::new();
        let root = model.snapshot().objects[0].address.clone();
        model
            .enqueue(WorldCommand::Structure {
                command: StructuralCommand {
                    command_id: "panel".into(),
                    operation: StructuralOperation::CreateInspector {
                        target: Some(root),
                        position: [1.0, 2.0, 3.0],
                        rotation: identity_rotation(),
                    },
                },
            })
            .unwrap();
        model.tick()[0].result.as_ref().unwrap();
        let expected = model.snapshot();
        let mut wire: ReplicatedWorld =
            serde_json::from_slice(&serde_json::to_vec(&REGISTRY.encode_world(&expected)).unwrap())
                .unwrap();
        for object in &mut wire.objects {
            object.components.reverse();
            for component in &mut object.components {
                component.fields.reverse();
            }
        }
        let decoded = REGISTRY.decode_world(wire).unwrap();
        model.restore(decoded).unwrap();
        assert_eq!(model.snapshot(), expected);
    }

    #[test]
    fn invalid_component_records_and_old_formats_never_replace_live_state() {
        let mut model = WorldModel::new();
        let before = model.snapshot();
        let source = REGISTRY.encode_world(&before);
        let mut variants = Vec::new();
        let mut value = source.clone();
        value.format_version += 1;
        variants.push(value);
        let mut value = source.clone();
        value.objects[0].components[0].version += 1;
        variants.push(value);
        let mut value = source.clone();
        value.objects[0].components[0].type_id = "Unregistered".into();
        variants.push(value);
        let mut value = source.clone();
        value.objects[0].components[0].address.instance_id = uuid::Uuid::new_v4().to_string();
        variants.push(value);
        let mut value = source.clone();
        value.objects[0].components.pop();
        variants.push(value);
        let mut value = source.clone();
        value.objects[0]
            .components
            .push(source.objects[0].components[0].clone());
        variants.push(value);
        let mut value = source.clone();
        value.objects[0].components[0].fields[0].value = json!(42);
        variants.push(value);
        let mut value = source.clone();
        value.objects[0].components[0].fields[0].revision = "999".into();
        variants.push(value);
        for value in variants {
            assert!(
                REGISTRY
                    .decode_world(value)
                    .and_then(|s| model.restore(s))
                    .is_err()
            );
            assert_eq!(model.snapshot(), before);
        }
        assert!(serde_json::from_value::<ReplicatedWorld>(json!(before)).is_err());
    }

    #[test]
    fn field_address_and_access_are_validated_before_mutation() {
        let mut model = WorldModel::new();
        let before = model.snapshot();
        let root = before.objects[0].address.clone();
        for (id, local_id, value) in [
            ("position", 1, json!([4.0, 5.0, 6.0])),
            ("visual", 2, json!({"kind":"cube"})),
            ("name", 999, json!("bad")),
        ] {
            model
                .enqueue(WorldCommand::Edit {
                    edit: Edit {
                        command_id: "bad".into(),
                        target: Address {
                            instance_id: root.instance_id.clone(),
                            local_id,
                        },
                        field_id: id.into(),
                        expected_revision: "0".into(),
                        value,
                    },
                })
                .unwrap();
            assert!(model.tick()[0].result.is_err());
            assert_eq!(model.snapshot(), before);
        }
        model
            .enqueue(WorldCommand::Edit {
                edit: Edit {
                    command_id: "valid".into(),
                    target: REGISTRY.field_address(&root, "position").unwrap(),
                    field_id: "position".into(),
                    expected_revision: "0".into(),
                    value: json!([4.0, 5.0, 6.0]),
                },
            })
            .unwrap();
        let commit = model.tick().remove(0).result.unwrap();
        let wire = REGISTRY.encode_commit(&commit);
        let mut guest = WorldModel::new();
        guest.restore(before).unwrap();
        guest
            .apply_commit(REGISTRY.decode_commit(wire).unwrap())
            .unwrap();
        assert_eq!(guest.snapshot(), model.snapshot());
    }
}
