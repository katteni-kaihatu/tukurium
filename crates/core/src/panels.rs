//! Shared panel semantics; Godot owns only rendering, hit testing and local input.
use crate::{components::*, resources::*, systems::bump_field};
use bevy_ecs::prelude::*;
use glam::{DMat3, DQuat, DVec3};
use kokoverse_protocol::{Address, AvatarPose, ObjectView, PanelAttachment, ScreenRect, Snapshot, Visual};
use serde_json::{Value, json};

pub const MAX_PANELS: usize = 16;

pub(crate) fn half_extents(size: [u32; 2]) -> [f64; 3] {
    [0.8 * size[0] as f64 / size[1] as f64, 0.8, 0.025]
}
pub const FIELDS: [&str; 7] = [
    "panel_size",
    "panel_pin",
    "inspector_target",
    "panel_scroll",
    "inspector_scripts_open",
    "inspector_script_id",
    "inspector_tree",
];

pub fn valid_address(value: &Value) -> bool {
    value.is_null()
        || serde_json::from_value::<Address>(value.clone())
            .is_ok_and(|a| a.local_id == 1 && uuid::Uuid::parse_str(&a.instance_id).is_ok())
}

pub(crate) fn validate_field(id: &str, value: &Value) -> Result<(), String> {
    let valid = match id {
        "inspector_tree" => serde_json::from_value::<kokoverse_protocol::InspectorTree>(value.clone()).is_ok_and(|tree| {
            valid_address(&json!(tree.root)) && tree.collapsed.len() <= crate::MAX_OBJECTS && tree.collapsed.iter().all(|a| valid_address(&json!(a)))
        }),
        "panel_size" => serde_json::from_value::<[u32; 2]>(value.clone())
            .is_ok_and(|v| v.iter().all(|x| (256..=1536).contains(x))),
        "inspector_target" => valid_address(value),
        "inspector_scripts_open" => value.is_boolean(),
        "inspector_script_id" => {
            value.is_null()
                || value
                    .as_str()
                    .is_some_and(|id| uuid::Uuid::parse_str(id).is_ok())
        }
        "panel_scroll" => serde_json::from_value::<[f64; 2]>(value.clone())
            .is_ok_and(|v| v.iter().all(|x| x.is_finite() && (0.0..=1.0).contains(x))),
        "panel_pin" => {
            value.is_null()
                || serde_json::from_value::<PanelAttachment>(value.clone()).is_ok_and(|a| {
                    !a.user_id.is_empty()
                        && a.user_id.len() <= 512
                        && a.offset.iter().all(|v| v.is_finite() && v.abs() <= 100.0)
                        && crate::validate_value("rotation", &json!(a.rotation)).is_ok()
                        && a.screen.as_ref().is_none_or(valid_screen)
                })
        }
        _ => false,
    };
    if valid {
        Ok(())
    } else {
        Err(format!("Invalid {id}"))
    }
}

fn valid_screen(screen: &ScreenRect) -> bool {
    let [x, y, w, h] = screen.rect;
    [x, y, w, h].iter().all(|v| v.is_finite())
        && (0.0..=1.0).contains(&x)
        && (0.0..=1.0).contains(&y)
        && (0.05..=1.0).contains(&w)
        && (0.05..=1.0).contains(&h)
        && x + w <= 1.001
        && y + h <= 1.001
        && screen.aspect.is_finite()
        && (0.4..=4.0).contains(&screen.aspect)
}

fn surface_components(object: &ObjectView) -> impl Iterator<Item = &'static crate::replication::ComponentRegistration> + '_ {
    crate::replication::REGISTRY.components.iter().filter(move |c| {
        matches!(c.type_id, "WorldPanel" | "InspectorView" | "CreationView") && (c.present)(object)
    })
}

pub(crate) fn append_fields(object: &mut ObjectView, revisions: &Revisions) {
    let values: Vec<_> = surface_components(object).flat_map(|c| {
        let values = (c.project)(object);
        c.fields.iter().map(move |f| (f, values[&f.schema.id].clone()))
    }).collect();
    for (registration, value) in values {
        let schema = &registration.schema;
        if let Some(field) = object.fields.iter_mut().find(|f| f.id == schema.id) {
            field.value = value;
        } else {
            object.fields.push(crate::field(&schema.id, &schema.label, &schema.value_type, value, revisions));
        }
    }
}

pub(crate) fn validate_object(object: &ObjectView) -> Result<(), String> {
    let is_panel = matches!(object.visual, Visual::Panel);
    let views = usize::from(object.inspector.is_some()) + usize::from(object.creation.is_some());
    if is_panel != object.panel.is_some() || views != usize::from(is_panel) {
        return Err("Panel visual requires one surface and one content component".into());
    }
    for component in surface_components(object) {
        let mut values = serde_json::Map::new();
        for registration in &component.fields {
            let field = object.fields.iter().find(|f| f.id == registration.schema.id).ok_or("Missing panel field")?;
            if field.value_type != registration.schema.value_type { return Err("Panel field type mismatch".into()); }
            (registration.validate)(&field.value)?;
            values.insert(field.id.clone(), field.value.clone());
        }
        let mut restored = object.clone();
        (component.restore)(&mut restored, &Value::Object(values))?;
        if (component.project)(&restored) != (component.project)(object) {
            return Err("Panel component does not match its fields".into());
        }
    }
    Ok(())
}

pub(crate) fn create(
    snapshot: &Snapshot,
    target: Option<Address>,
    position: [f64; 3],
    rotation: [f64; 4],
) -> Result<ObjectView, String> {
    if snapshot.objects.len() >= crate::MAX_OBJECTS
        || snapshot
            .objects
            .iter()
            .filter(|o| o.panel.is_some())
            .count()
            >= MAX_PANELS
    {
        return Err("Panel limit reached (16 panels / 128 objects)".into());
    }
    if target
        .as_ref()
        .is_some_and(|a| !snapshot.objects.iter().any(|o| &o.address == a))
    {
        return Err("Inspector target no longer exists".into());
    }
    crate::validate_value("position", &json!(position))?;
    crate::validate_value("rotation", &json!(rotation))?;
    let mut object = crate::new_object("Inspector".into(), position, [1.0; 4]);
    object.visual = Visual::Panel;
    object.world_rotation = rotation;
    object.panel = Some(kokoverse_protocol::WorldPanel {
        size: [1120, 960],
        attachment: None,
    });
    object.inspector = Some(kokoverse_protocol::InspectorView {
        target,
        scroll: [0.0; 2],
        scripts_open: false,
        script_id: None,
        tree: Default::default(),
    });
    crate::set_default_collider(&mut object);
    Ok(object)
}

pub(crate) fn create_creation(
    snapshot: &Snapshot, position: [f64; 3], rotation: [f64; 4],
) -> Result<ObjectView, String> {
    let mut object = create(snapshot, None, position, rotation)?;
    object.inspector = None;
    object.creation = Some(kokoverse_protocol::CreationView {shape: kokoverse_protocol::PrimitiveShape::Box});
    object.panel.as_mut().unwrap().size = [1120, 720];
    object.fields.iter_mut().find(|f| f.id == "name").unwrap().value = json!("Create new");
    crate::set_default_collider(&mut object);
    Ok(object)
}

pub(crate) fn write_field(world: &mut World, entity: Entity, field: &str, value: Value) {
    match field {
        "inspector_tree" => world.get_mut::<InspectorView>(entity).unwrap().0.tree = serde_json::from_value(value).unwrap(),
        "panel_size" => {
            let old_size = world.get::<WorldPanel>(entity).unwrap().0.size;
            let size = serde_json::from_value(value).unwrap();
            world.get_mut::<WorldPanel>(entity).unwrap().0.size = size;
            // Resize the default pick shape with the surface, preserving custom colliders.
            if let Some(mut collider) = world.get_mut::<Collider>(entity)
                && collider.0.half_extents == half_extents(old_size)
            {
                collider.0.half_extents = half_extents(size);
                bump_field(world, entity, "collider");
            }
        }
        "panel_pin" => {
            world.get_mut::<WorldPanel>(entity).unwrap().0.attachment =
                serde_json::from_value(value).unwrap()
        }
        "inspector_target" => {
            let mut inspector = world.get_mut::<InspectorView>(entity).unwrap();
            inspector.0.target = serde_json::from_value(value).unwrap();
            inspector.0.scroll = [0.0; 2];
            inspector.0.script_id = None;
            for field in ["panel_scroll", "inspector_script_id"] {
                *world
                    .get_mut::<Revisions>(entity)
                    .unwrap()
                    .0
                    .entry(field.into())
                    .or_default() += 1;
            }
        }
        "inspector_scripts_open" => {
            world
                .get_mut::<InspectorView>(entity)
                .unwrap()
                .0
                .scripts_open = serde_json::from_value(value).unwrap()
        }
        "inspector_script_id" => {
            world.get_mut::<InspectorView>(entity).unwrap().0.script_id =
                serde_json::from_value(value).unwrap()
        }
        "panel_scroll" => {
            world.get_mut::<InspectorView>(entity).unwrap().0.scroll =
                serde_json::from_value(value).unwrap()
        }
        _ => unreachable!(),
    }
}

pub(crate) fn apply_field(world: &mut World, entity: Entity, field: &str, value: Value) {
    write_field(world, entity, field, value);
    bump_field(world, entity, field);
}

pub(crate) fn target_removed(world: &mut World, address: &Address) {
    let trees: Vec<_> = world.query::<(Entity, &InspectorView)>().iter(world).filter_map(|(e,i)| {
        let mut tree=i.0.tree.clone();
        let original=tree.clone();
        if tree.root.as_ref()==Some(address) {tree.root=None;}
        tree.collapsed.retain(|a| a!=address);
        (tree!=original).then_some((e,tree))
    }).collect();
    for (entity,tree) in trees { apply_field(world,entity,"inspector_tree",json!(tree)); }
    let mut query = world.query::<(Entity, &InspectorView)>();
    let affected: Vec<_> = query
        .iter(world)
        .filter(|(_, i)| i.0.target.as_ref() == Some(address))
        .map(|(e, _)| e)
        .collect();
    for e in affected {
        apply_field(world, e, "inspector_target", Value::Null);
    }
}

/// Eye height matches the FPS camera in `main.gd`. Vertical FOV matches Godot's Camera3D default.
const EYE_HEIGHT: f64 = 1.15;
const VIEW_FOV_Y: f64 = 75.0_f64.to_radians();
const PANEL_HEIGHT: f64 = 1.6;

fn view_basis(yaw: f64, pitch: f64) -> (DVec3, DVec3, DVec3) {
    let (sy, cy) = yaw.sin_cos();
    let (sp, cp) = pitch.sin_cos();
    (
        DVec3::new(cy, 0.0, -sy),
        DVec3::new(-sy * sp, cp, -cy * sp),
        DVec3::new(-sy * cp, -sp, -cy * cp),
    )
}

/// Place the panel on the owner's view plane so its center matches `screen.rect` in the window.
fn screen_pose(pose: &AvatarPose, screen: &ScreenRect) -> ([f64; 3], [f64; 4]) {
    let [x, y, w, h] = screen.rect;
    let h = h.clamp(0.08, 1.0);
    let half_fov = VIEW_FOV_Y * 0.5;
    let mut distance = (PANEL_HEIGHT / h) / (2.0 * half_fov.tan());
    distance = distance.clamp(0.45, 6.0);
    let vis_h = 2.0 * distance * half_fov.tan();
    let vis_w = vis_h * screen.aspect.clamp(0.4, 4.0);
    let ndc_x = ((x + w * 0.5).clamp(0.0, 1.0)) * 2.0 - 1.0;
    let ndc_y = 1.0 - ((y + h * 0.5).clamp(0.0, 1.0)) * 2.0;
    let (right, up, forward) = view_basis(pose.yaw, pose.pitch);
    let eye = DVec3::from_array(pose.position) + DVec3::Y * EYE_HEIGHT;
    let position = eye + right * (ndc_x * vis_w * 0.5) + up * (ndc_y * vis_h * 0.5) + forward * distance;
    let rotation = DQuat::from_mat3(&DMat3::from_cols(right, up, -forward)).to_array();
    (position.to_array(), rotation)
}

/// Runs only on the authority, producing normal transform commits at the authoring boundary.
pub(crate) fn follow_users(world: &mut World) {
    let participants = world
        .resource::<crate::presence::PresenceCache>()
        .participants
        .clone();
    let mut query = world.query::<(Entity, &WorldPanel, &LocalTransform)>();
    let changes: Vec<_> = query
        .iter(world)
        .filter_map(|(e, p, t)| {
            let attachment = p.0.attachment.as_ref()?;
            let user = participants.iter().find(|u| u.id == attachment.user_id);
            Some((e, attachment.clone(), user.map(|u| u.pose.clone()), *t))
        })
        .collect();
    let mut changed = false;
    for (entity, attachment, pose, old) in changes {
        let Some(pose) = pose else {
            apply_field(world, entity, "panel_pin", Value::Null);
            changed = true;
            continue;
        };
        let (position, rotation) = if let Some(screen) = &attachment.screen {
            screen_pose(&pose, screen)
        } else {
            let (s, c) = pose.yaw.sin_cos();
            let [x, y, z] = attachment.offset;
            let position = [
                pose.position[0] + c * x + s * z,
                pose.position[1] + y,
                pose.position[2] - s * x + c * z,
            ];
            let (s, c) = (pose.yaw * 0.5).sin_cos();
            let [x, y, z, w] = attachment.rotation;
            let rotation = [c * x + s * z, c * y + s * w, c * z - s * x, c * w - s * y];
            (position, rotation)
        };
        if position != old.translation || rotation != old.rotation {
            if crate::validate_value("position", &json!(position)).is_err() {
                continue;
            }
            let mut transform = world.get_mut::<LocalTransform>(entity).unwrap();
            transform.translation = position;
            transform.rotation = rotation;
            for field in ["position", "rotation"] {
                *world
                    .get_mut::<Revisions>(entity)
                    .unwrap()
                    .0
                    .entry(field.into())
                    .or_default() += 1;
            }
            world.get_mut::<ObjectRoot>(entity).unwrap().revision += 1;
            changed = true;
        }
    }
    if changed {
        world.resource_mut::<WorldRevision>().0 += 1;
        world.resource_mut::<Applied>().0 = Some(AppliedCommand {
            ticket: 0,
            result: Ok(None),
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{WorldModel, edit_sessions::EditSessions};
    use kokoverse_protocol::{
        Edit, EditDraft, EditSessionRequest, StructuralCommand, StructuralOperation, WorldCommand,
    };

    fn panel(model: &mut WorldModel, target: Address) -> Address {
        model
            .enqueue(WorldCommand::Structure {
                command: StructuralCommand {
                    command_id: uuid::Uuid::new_v4().to_string(),
                    operation: StructuralOperation::CreateInspector {
                        target: Some(target),
                        position: [0.0, 1.5, 2.0],
                        rotation: [0.0, 0.0, 0.0, 1.0],
                    },
                },
            })
            .unwrap();
        let outcome = model.tick().remove(0);
        outcome.result.unwrap();
        outcome.selected.unwrap()
    }
    #[test]
    fn resizing_panel_keeps_pick_shape_and_saved_surface_in_agreement() {
        let mut model = WorldModel::new();
        let target = model.snapshot().objects[0].address.clone();
        let id = panel(&mut model, target);
        let before = model.snapshot().objects.iter().find(|o| o.address == id).unwrap().clone();
        assert_eq!(before.collider.unwrap().half_extents, half_extents([1120, 960]));
        model.enqueue(WorldCommand::Edit { edit: Edit {
            command_id: "resize".into(),
            target: crate::replication::REGISTRY.field_address(&id, "panel_size").unwrap(),
            field_id: "panel_size".into(), expected_revision: "0".into(), value: json!([1024, 768]),
        }}).unwrap();
        model.tick()[0].result.as_ref().unwrap();
        let snapshot = model.snapshot();
        let resized = snapshot.objects.iter().find(|o| o.address == id).unwrap();
        assert_eq!(resized.collider.as_ref().unwrap().half_extents, half_extents([1024, 768]));
        assert_eq!(resized.fields.iter().find(|f| f.id == "collider").unwrap().revision, "1");
        let mut restored = WorldModel::new();
        restored.restore(snapshot.clone()).unwrap();
        assert_eq!(restored.snapshot(), snapshot);
    }

    #[test]
    fn panels_have_independent_state_and_survive_restore() {
        let mut model = WorldModel::new();
        let target = model.snapshot().objects[0].address.clone();
        let a = panel(&mut model, target.clone());
        let b = panel(&mut model, target.clone());
        model
            .enqueue(WorldCommand::Edit {
                edit: Edit {
                    command_id: "scroll".into(),
                    target: crate::replication::REGISTRY
                        .field_address(&a, "panel_scroll")
                        .unwrap(),
                    field_id: "panel_scroll".into(),
                    expected_revision: "0".into(),
                    value: json!([0.0, 0.6]),
                },
            })
            .unwrap();
        model.tick()[0].result.as_ref().unwrap();
        let snapshot = model.snapshot();
        assert_eq!(
            snapshot
                .objects
                .iter()
                .find(|o| o.address == a)
                .unwrap()
                .inspector
                .as_ref()
                .unwrap()
                .scroll,
            [0.0, 0.6]
        );
        assert_eq!(
            snapshot
                .objects
                .iter()
                .find(|o| o.address == b)
                .unwrap()
                .inspector
                .as_ref()
                .unwrap()
                .scroll,
            [0.0; 2]
        );
        let mut restored = WorldModel::new();
        restored.restore(snapshot.clone()).unwrap();
        assert_eq!(restored.snapshot(), snapshot);
        let mut wire = snapshot.clone();
        for object in &mut wire.objects {
            if let Some(field) = object
                .fields
                .iter_mut()
                .find(|f| f.id == "panel_scroll" && f.value == json!([0.0, 0.0]))
            {
                field.value = json!([0, 0]);
            }
        }
        restored.restore(wire).unwrap();
        let revision = snapshot
            .objects
            .iter()
            .find(|o| o.address == target)
            .unwrap()
            .object_revision
            .clone();
        restored
            .enqueue(WorldCommand::Structure {
                command: StructuralCommand {
                    command_id: "delete".into(),
                    operation: StructuralOperation::Delete {
                        target,
                        expected_revision: revision,
                    },
                },
            })
            .unwrap();
        restored.tick()[0].result.as_ref().unwrap();
        assert!(
            restored
                .snapshot()
                .objects
                .iter()
                .all(|o| o.inspector.as_ref().is_none_or(|i| i.target.is_none()))
        );
        let snapshot = restored.snapshot();
        restored.restore(snapshot).unwrap();
    }
    #[test]
    fn lease_spans_panels_but_expires_and_is_not_saved() {
        let mut model = WorldModel::new();
        let target = model.snapshot().objects[0].address.clone();
        let a = panel(&mut model, target.clone());
        let b = panel(&mut model, target.clone());
        let now = std::time::Instant::now();
        let mut leases = EditSessions::default();
        let request = EditSessionRequest {
            command_id: "1".into(),
            client_id: "a".into(),
            context: Some(kokoverse_protocol::EditContext {
                source: crate::replication::REGISTRY
                    .field_address(&a, "inspector_target")
                    .unwrap(),
                field_id: "inspector_target".into(),
            }),
            target: target.clone(),
            field_id: "name".into(),
            action: "begin".into(),
            draft: EditDraft::default(),
        };
        leases
            .apply("alice", request.clone(), &model.snapshot(), now)
            .unwrap();
        let mut end_payload = serde_json::to_value(&request).unwrap();
        end_payload["action"] = json!("end");
        end_payload["draft"] = json!({});
        let end: EditSessionRequest = serde_json::from_value(end_payload).unwrap();
        leases.apply("alice", end, &model.snapshot(), now).unwrap();
        assert!(leases.views().is_empty());
        leases
            .apply("alice", request.clone(), &model.snapshot(), now)
            .unwrap();
        let mut other = request.clone();
        other.context.as_mut().unwrap().source = crate::replication::REGISTRY
            .field_address(&b, "inspector_target")
            .unwrap();
        other.client_id = "b".into();
        assert!(
            leases
                .apply("bob", other.clone(), &model.snapshot(), now)
                .is_err()
        );
        let edit = WorldCommand::Edit {
            edit: Edit {
                command_id: "2".into(),
                target,
                field_id: "name".into(),
                expected_revision: "0".into(),
                value: json!("Bob"),
            },
        };
        assert!(leases.check_command("bob", &edit).is_err());
        assert!(leases.check_command("alice", &edit).is_ok());
        assert!(
            !serde_json::to_string(&model.snapshot())
                .unwrap()
                .contains("alice")
        );
        leases
            .apply(
                "bob",
                other,
                &model.snapshot(),
                now + std::time::Duration::from_secs(7),
            )
            .unwrap();
        leases.forget("bob");
        assert!(leases.views().is_empty());
    }
    #[test]
    fn rejects_forged_panel_data_and_limits_count() {
        let mut model = WorldModel::new();
        let target = model.snapshot().objects[0].address.clone();
        for _ in 0..MAX_PANELS {
            panel(&mut model, target.clone());
        }
        assert!(
            create(
                &model.snapshot(),
                Some(target),
                [0.0; 3],
                [0.0, 0.0, 0.0, 1.0]
            )
            .is_err()
        );
        let mut bad = model.snapshot();
        bad.objects
            .iter_mut()
            .find(|o| o.panel.is_some())
            .unwrap()
            .panel
            .as_mut()
            .unwrap()
            .size = [4000, 4000];
        assert!(model.restore(bad).is_err());
    }

    #[test]
    fn pinned_screen_rect_follows_the_owner_window() {
        use kokoverse_protocol::{AvatarPose, ParticipantView, PlayerInput};
        use std::time::Duration;
        let mut model = WorldModel::new();
        model
            .update_participant(ParticipantView {
                avatar_texture: None,
                id: "local".into(),
                name: "Test".into(),
                pose: AvatarPose { position: [0.0; 3], yaw: 0.0, pitch: 0.0 },
            })
            .unwrap();
        model.tick();
        model.enable_local_player("local").unwrap();
        model.set_script_authority(true);
        model
            .set_player_input(PlayerInput { active: true, yaw: 0.0, pitch: 0.0, ..PlayerInput::default() })
            .unwrap();
        model.advance(Duration::from_millis(50));
        let target = model.snapshot().objects[0].address.clone();
        let id = panel(&mut model, target);
        let pin = crate::replication::REGISTRY.field_address(&id, "panel_pin").unwrap();
        model
            .enqueue(WorldCommand::Edit {
                edit: Edit {
                    command_id: "pin".into(),
                    target: pin,
                    field_id: "panel_pin".into(),
                    expected_revision: "0".into(),
                    value: json!({
                        "user_id": "local",
                        "offset": [0.0, 1.15, -1.2],
                        "rotation": [0.0, 0.0, 0.0, 1.0],
                        "screen": {"rect": [0.62, 0.2, 0.3, 0.45], "aspect": 16.0 / 9.0}
                    }),
                },
            })
            .unwrap();
        model.advance(Duration::from_millis(50));
        let placed = model.snapshot().objects.into_iter().find(|o| o.address == id).unwrap();
        let pos = placed.world_position;
        assert!(pos[0] > 0.2, "right side of the window should sit to the owner's right, got {pos:?}");
        assert!(pos[2] < -0.4, "the panel should sit in front of the owner, got {pos:?}");
        assert!(pos[1] > 0.6, "the panel should stay near eye height, got {pos:?}");
        assert!(placed.panel.unwrap().attachment.unwrap().screen.is_some());
    }
}
