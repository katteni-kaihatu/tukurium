//! Generic collider extraction and kinematic character collision against oriented boxes.
use crate::{Collider, GlobalTransform, Identity, Revisions};
use bevy_ecs::prelude::*;
use glam::{DAffine3, DQuat, DVec3};
use kokoverse_protocol::{Address, ObjectPreview};
pub const RADIUS: f64 = 0.28;
pub const HEIGHT: f64 = 1.7;
pub const EYE_HEIGHT: f64 = 1.15;
const SKIN: f64 = 0.0001;
#[derive(Clone, Debug)]
pub(crate) struct Bounds {
    pub address: Address,
    pub center: [f64; 3],
    pub rotation: DQuat,
    pub scale: [f64; 3],
    pub half: DVec3,
    pub solid: bool,
}
impl Bounds {
    pub(crate) fn intersects(&self, other: &Self) -> bool {
        // Same separating-axis test as before, but the candidate
        // axes are tested on the fly instead of being collected into
        // a heap Vec on every pair check (contacts run this for every
        // sensor x object pair each step). The per-axis arithmetic is
        // unchanged, and a conjunction's result does not depend on
        // evaluation order, so the outcome is identical.
        let basis = |rotation: DQuat| [rotation * DVec3::X, rotation * DVec3::Y, rotation * DVec3::Z];
        let a = basis(self.rotation);
        let b = basis(other.rotation);
        let distance = DVec3::from_array(other.center) - DVec3::from_array(self.center);
        let separated = |axis: DVec3| {
            let radius = |half: DVec3, basis: [DVec3; 3]| {
                half.x * basis[0].dot(axis).abs()
                    + half.y * basis[1].dot(axis).abs()
                    + half.z * basis[2].dot(axis).abs()
            };
            distance.dot(axis).abs() > radius(self.half, a) + radius(other.half, b) + 1e-9
        };
        if a.iter().chain(b.iter()).any(|&axis| separated(axis)) {
            return false;
        }
        for left in a {
            for right in b {
                let axis = left.cross(right);
                if axis.length_squared() > 1e-12 && separated(axis.normalize()) {
                    return false;
                }
            }
        }
        true
    }
    pub fn frame(&self) -> DAffine3 {
        DAffine3::from_scale_rotation_translation(
            DVec3::from_array(self.scale),
            self.rotation,
            DVec3::from_array(self.center),
        )
    }
    pub fn raycast(
        &self,
        origin: [f64; 3],
        direction: [f64; 3],
        limit: f64,
    ) -> Option<(f64, [f64; 3])> {
        let local = self.rotation.conjugate()
            * (DVec3::from_array(origin) - DVec3::from_array(self.center));
        let dir = self.rotation.conjugate() * DVec3::from_array(direction);
        ray_box(
            local.to_array(),
            dir.to_array(),
            (-self.half).to_array(),
            self.half.to_array(),
            limit,
        )
        .map(|(t, n)| (t, (self.rotation * DVec3::from_array(n)).to_array()))
    }
    /// The separating axes for the character sweep/penetration
    /// tests: 3 world axes, 3 rotated axes, and up to 9 cross
    /// products. Previously allocated a Vec on every call (several
    /// times per collider per step); now returned as a fixed-size
    /// stack buffer plus its live length, with identical contents
    /// and order.
    fn axes(&self) -> ([DVec3; 15], usize) {
        let world = [DVec3::X, DVec3::Y, DVec3::Z];
        let oriented = world.map(|a| self.rotation * a);
        let mut axes = [DVec3::ZERO; 15];
        let mut len = 0;
        for axis in world.into_iter().chain(oriented) {
            axes[len] = axis;
            len += 1;
        }
        for a in world {
            for b in oriented {
                let c = a.cross(b);
                if c.length_squared() > 1e-12 {
                    axes[len] = c.normalize();
                    len += 1;
                }
            }
        }
        (axes, len)
    }
    fn radius(&self, axis: DVec3) -> f64 {
        let character = DVec3::new(RADIUS, HEIGHT * 0.5, RADIUS);
        axis.abs().dot(character) + (self.rotation.conjugate() * axis).abs().dot(self.half)
    }
    fn sweep(&self, position: [f64; 3], delta: [f64; 3]) -> Option<(f64, DVec3)> {
        let relative = DVec3::from_array(position) + DVec3::Y * (HEIGHT * 0.5)
            - DVec3::from_array(self.center);
        let movement = DVec3::from_array(delta);
        let mut enter: f64 = 0.0;
        let mut exit: f64 = 1.0;
        let mut normal = DVec3::ZERO;
        let (axes, axes_len) = self.axes();
        for axis in axes[..axes_len].iter().copied() {
            let distance = relative.dot(axis);
            let speed = movement.dot(axis);
            let radius = self.radius(axis);
            if speed.abs() < 1e-12 {
                if distance.abs() >= radius - 1e-9 {
                    return None;
                }
            } else {
                let a = (-radius - distance) / speed;
                let b = (radius - distance) / speed;
                let near = a.min(b);
                exit = exit.min(a.max(b));
                if near >= enter {
                    enter = near;
                    normal = -speed.signum() * axis;
                }
                if enter > exit {
                    return None;
                }
            }
        }
        if exit < 0.0 || enter > 1.0 || normal == DVec3::ZERO {
            None
        } else {
            Some((enter, normal))
        }
    }
    fn penetration(&self, position: [f64; 3]) -> Option<DVec3> {
        let relative = DVec3::from_array(position) + DVec3::Y * (HEIGHT * 0.5)
            - DVec3::from_array(self.center);
        let mut best: Option<DVec3> = None;
        let (axes, axes_len) = self.axes();
        for axis in axes[..axes_len].iter().copied() {
            let distance = relative.dot(axis);
            let depth = self.radius(axis) - distance.abs();
            if depth <= 1e-9 {
                return None;
            }
            let normal = if distance < 0.0 { -axis } else { axis };
            let push = normal * (depth + SKIN);
            if position[1] + push.y < -SKIN {
                continue;
            }
            if best.is_none_or(|b| push.length_squared() < b.length_squared()) {
                best = Some(push);
            }
        }
        best
    }
}
#[derive(Resource, Default)]
pub(crate) struct CollisionWorld(pub Vec<Bounds>);
#[derive(Resource, Default, Clone)]
pub(crate) struct PreviewPositions(pub Vec<ObjectPreview>);
pub(crate) fn preview_matches(p: &ObjectPreview, revisions: &Revisions) -> bool {
    let matches = |id: &str, revision: &str| {
        revisions.0.get(id).copied().unwrap_or(0).to_string() == revision
    };
    matches("position", &p.expected_revision)
        && p.expected_rotation_revision
            .as_ref()
            .is_none_or(|r| matches("rotation", r))
        && p.expected_scale_revision
            .as_ref()
            .is_none_or(|r| matches("scale", r))
}
type ColliderData<'a> = (
    &'a Identity,
    &'a GlobalTransform,
    &'a Collider,
    &'a Revisions,
    Option<&'a crate::drives::DrivenFields>,
    Option<&'a crate::hierarchy::EvaluatedGlobal>,
);
pub(crate) fn sync_colliders(
    shapes: Query<ColliderData>,
    previews: Res<PreviewPositions>,
    grab: Res<crate::grabbing::GrabState>,
    mut colliders: ResMut<CollisionWorld>,
) {
    colliders.0.clear();
    for (identity, transform, shape, revisions, driven, evaluated) in &shapes {
        let preview = grab
            .0
            .as_ref()
            .map(|g| &g.view.preview)
            .filter(|p| p.target == identity.0)
            .or_else(|| previews.0.iter().find(|p| p.target == identity.0))
            .filter(|p| preview_matches(p, revisions));
        let read = |field: &str| driven.and_then(|d| d.0.get(field)).cloned();
        let base_position = read("position")
            .and_then(|v| serde_json::from_value(v).ok())
            .unwrap_or(transform.translation);
        let base_rotation = read("rotation")
            .and_then(|v| serde_json::from_value(v).ok())
            .unwrap_or(transform.rotation);
        let base_scale = read("scale")
            .and_then(|v| serde_json::from_value(v).ok())
            .unwrap_or(transform.scale);
        let effective = evaluated.map(|v| v.0);
        let center = preview.map_or(effective.map_or(base_position, |v| v.translation), |p| {
            p.position
        });
        let rotation = preview
            .and_then(|p| p.rotation)
            .unwrap_or(effective.map_or(base_rotation, |v| v.rotation));
        let scale = preview
            .and_then(|p| p.scale)
            .unwrap_or(effective.map_or(base_scale, |v| v.scale));
        colliders.0.push(Bounds {
            address: identity.0.clone(),
            center,
            rotation: DQuat::from_array(rotation).normalize(),
            scale,
            half: DVec3::from_array(shape.0.half_extents) * DVec3::from_array(scale),
            solid: shape.0.solid,
        });
    }
    colliders
        .0
        .sort_by(|a, b| a.address.instance_id.cmp(&b.address.instance_id));
}
pub(crate) fn ray_box(
    origin: [f64; 3],
    direction: [f64; 3],
    min: [f64; 3],
    max: [f64; 3],
    limit: f64,
) -> Option<(f64, [f64; 3])> {
    let mut enter: f64 = 0.0;
    let mut exit = limit;
    let mut normal = [0.0; 3];
    for axis in 0..3 {
        if direction[axis].abs() < 1e-12 {
            if origin[axis] <= min[axis] + 1e-9 || origin[axis] >= max[axis] - 1e-9 {
                return None;
            }
        } else {
            let a = (min[axis] - origin[axis]) / direction[axis];
            let b = (max[axis] - origin[axis]) / direction[axis];
            let near = a.min(b);
            exit = exit.min(a.max(b));
            if near >= enter {
                enter = near;
                normal = [0.0; 3];
                normal[axis] = -direction[axis].signum();
            }
            if enter > exit {
                return None;
            }
        }
    }
    if exit < 0.0 || enter > limit || normal == [0.0; 3] {
        None
    } else {
        Some((enter, normal))
    }
}
fn included(bounds: &Bounds, ignored: Option<&Address>) -> bool {
    bounds.solid && ignored != Some(&bounds.address)
}
pub(crate) fn depenetrate(position: &mut [f64; 3], boxes: &[Bounds], ignored: Option<&Address>) {
    position[1] = position[1].max(0.0);
    for _ in 0..12 {
        let push = boxes
            .iter()
            .filter(|b| included(b, ignored))
            .filter_map(|b| b.penetration(*position))
            .min_by(|a, b| a.length_squared().total_cmp(&b.length_squared()));
        let Some(push) = push else {
            break;
        };
        *position = (DVec3::from_array(*position) + push).to_array();
    }
}
pub(crate) fn move_and_slide(
    position: &mut [f64; 3],
    delta: [f64; 3],
    velocity: &mut [f64; 3],
    boxes: &[Bounds],
    ignored: Option<&Address>,
) {
    let mut remaining = DVec3::from_array(delta);
    for _ in 0..6 {
        if remaining.length_squared() < 1e-20 {
            break;
        }
        let mut hit = if remaining.y < 0.0 && position[1] + remaining.y < 0.0 {
            Some((-position[1] / remaining.y, DVec3::Y))
        } else {
            None
        };
        for bounds in boxes.iter().filter(|b| included(b, ignored)) {
            if let Some(candidate) = bounds.sweep(*position, remaining.to_array())
                && hit.is_none_or(|h| candidate.0 < h.0)
            {
                hit = Some(candidate);
            }
        }
        let Some((time, normal)) = hit else {
            *position = (DVec3::from_array(*position) + remaining).to_array();
            break;
        };
        *position = (DVec3::from_array(*position) + remaining * time + normal * SKIN).to_array();
        remaining *= 1.0 - time;
        remaining -= normal * remaining.dot(normal).min(0.0);
        let mut v = DVec3::from_array(*velocity);
        v -= normal * v.dot(normal).min(0.0);
        *velocity = v.to_array();
    }
    position[0] = position[0].clamp(-1000.0, 1000.0);
    position[1] = position[1].clamp(0.0, 1000.0);
    position[2] = position[2].clamp(-1000.0, 1000.0);
}
pub(crate) fn support<'a>(
    position: [f64; 3],
    boxes: &'a [Bounds],
    ignored: Option<&Address>,
) -> Option<&'a Bounds> {
    boxes
        .iter()
        .filter(|b| included(b, ignored))
        .filter_map(|b| {
            b.sweep(position, [0.0, -0.006, 0.0])
                .filter(|(_, n)| n.y > 0.65)
                .map(|(t, _)| (t, b))
        })
        .min_by(|a, b| a.0.total_cmp(&b.0))
        .map(|(_, b)| b)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::WorldModel;
    use kokoverse_protocol::{AvatarPose, ParticipantView, PlayerInput};
    use std::time::Duration;

    #[test]
    fn rotated_scaled_collider_uses_oriented_shape_for_ray_and_sweep() {
        let b = Bounds {
            address: Address::default(),
            center: [0.0, 0.75, 0.0],
            rotation: DQuat::from_rotation_y(std::f64::consts::FRAC_PI_4),
            scale: [2.0, 1.0, 1.0],
            half: DVec3::new(1.5, 0.75, 0.75),
            solid: true,
        };
        let hit = b.raycast([0.0, 0.75, 3.0], [0.0, 0.0, -1.0], 6.0).unwrap();
        assert!((hit.0 - (3.0 - 0.75 * 2.0_f64.sqrt())).abs() < 1e-6);
        // This ray enters the enclosing AABB but misses the actual rotated box.
        assert!(b.raycast([1.5, 0.75, 3.0], [0.0, 0.0, -1.0], 2.0).is_none());
        let (t, normal) = b.sweep([0.0, 0.0, 3.0], [0.0, 0.0, -3.0]).unwrap();
        assert!(t > 0.0 && t < 1.0);
        assert!(normal.x.abs() > 0.7 && normal.z > 0.7);
    }

    #[test]
    fn xr_view_guard_rejects_walls_and_invalid_positions_without_moving_player() {
        let mut m = model([0.0, 0.75, 0.0], [0.0, 0.0, 2.0]);
        step(&mut m, PlayerInput::default());
        let before = m.local_player().unwrap();
        let snapshot = m.snapshot();
        assert!(m.view_position_clear([0.0, 1.5, 2.0]));
        assert!(!m.view_position_clear([0.0, 1.4, 0.7]));
        assert!(!m.view_position_clear([f64::NAN, 1.5, 2.0]));
        assert!(!m.view_position_clear([0.0, -1.0, 2.0]));
        assert_eq!(m.local_player().unwrap(), before);
        assert_eq!(m.snapshot(), snapshot);
    }
    fn model(box_position: [f64; 3], player: [f64; 3]) -> WorldModel {
        let mut m = WorldModel::new();
        let mut s = m.snapshot();
        s.objects[0].world_position = box_position;
        s.objects[0]
            .fields
            .iter_mut()
            .find(|f| f.id == "position")
            .unwrap()
            .value = serde_json::json!(box_position);
        m.restore(s).unwrap();
        m.update_participant(ParticipantView {
            avatar_texture: None,
            id: "local".into(),
            name: "Test".into(),
            pose: AvatarPose {
                position: player,
                yaw: 0.0,
                pitch: 0.0,
            },
        })
        .unwrap();
        m.tick();
        m.enable_local_player("local").unwrap();
        m
    }
    fn step(m: &mut WorldModel, input: PlayerInput) {
        m.set_player_input(input).unwrap();
        m.advance(Duration::from_secs_f64(crate::locomotion::FIXED_STEP));
    }
    fn position(m: &WorldModel) -> [f64; 3] {
        m.local_player().unwrap().pose.position
    }
    #[test]
    fn walls_block_and_allow_sliding() {
        let mut m = model([0.0, 0.75, 0.0], [0.0, 0.0, 2.0]);
        for _ in 0..40 {
            step(
                &mut m,
                PlayerInput {
                    movement: [0.0, -1.0],
                    active: true,
                    ..Default::default()
                },
            );
        }
        assert!((position(&m)[2] - 1.0301).abs() < 0.002);
        for _ in 0..10 {
            step(
                &mut m,
                PlayerInput {
                    movement: [1.0, -1.0],
                    active: true,
                    ..Default::default()
                },
            );
        }
        assert!(position(&m)[0] > 0.4 && position(&m)[2] >= 1.03);
    }
    #[test]
    fn jumping_lands_on_box_and_walking_off_falls() {
        let mut m = model([0.0, 0.75, 0.0], [0.0, 0.0, 1.5]);
        for n in 0..60 {
            step(
                &mut m,
                PlayerInput {
                    movement: if n < 30 { [0.0, -1.0] } else { [0.0; 2] },
                    jump: n == 0,
                    active: true,
                    ..Default::default()
                },
            );
        }
        assert!((position(&m)[1] - 1.5).abs() < 0.002, "{:?}", position(&m));
        assert!(m.local_motion().unwrap().grounded);
        for _ in 0..60 {
            step(
                &mut m,
                PlayerInput {
                    movement: [1.0, 0.0],
                    active: true,
                    ..Default::default()
                },
            );
        }
        assert_eq!(position(&m)[1], 0.0);
    }
    #[test]
    fn underside_stops_jump() {
        let mut m = model([0.0, 3.0, 0.0], [0.0; 3]);
        let mut peak: f64 = 0.0;
        for n in 0..60 {
            step(
                &mut m,
                PlayerInput {
                    jump: n == 0,
                    active: true,
                    ..Default::default()
                },
            );
            peak = peak.max(position(&m)[1]);
        }
        assert!(peak > 0.4 && peak < 0.551);
        assert_eq!(position(&m)[1], 0.0);
    }
    #[test]
    fn preview_moves_collider_and_resolves_new_overlap() {
        let mut m = model([0.0, 0.75, 0.0], [0.0, 0.0, 2.0]);
        let object = m.snapshot().objects.remove(0);
        m.set_collision_previews(vec![ObjectPreview {
            target: object.address,
            expected_revision: "0".into(),
            position: [0.0, 0.75, 2.0],
            ..Default::default()
        }]);
        step(&mut m, PlayerInput::default());
        let p = position(&m);
        assert!(
            p[0].abs() >= 1.03 || (p[2] - 2.0).abs() >= 1.03 || p[1] >= 1.5,
            "{p:?}"
        );
        assert_eq!(m.snapshot().world_revision, "0");
    }
    // --- Equivalence references: the pre-change implementations,
    // kept verbatim so the optimized versions can be checked
    // against them on generated inputs. ---
    fn reference_axes(rotation: DQuat) -> Vec<DVec3> {
        let world = [DVec3::X, DVec3::Y, DVec3::Z];
        let oriented = world.map(|a| rotation * a);
        let mut axes = Vec::from(world);
        axes.extend(oriented);
        for a in world {
            for b in oriented {
                let c = a.cross(b);
                if c.length_squared() > 1e-12 {
                    axes.push(c.normalize());
                }
            }
        }
        axes
    }
    fn reference_intersects(me: &Bounds, other: &Bounds) -> bool {
        let basis = |rotation: DQuat| [rotation * DVec3::X, rotation * DVec3::Y, rotation * DVec3::Z];
        let a = basis(me.rotation);
        let b = basis(other.rotation);
        let mut axes = Vec::from(a);
        axes.extend(b);
        for left in a {
            for right in b {
                let axis = left.cross(right);
                if axis.length_squared() > 1e-12 { axes.push(axis.normalize()); }
            }
        }
        let distance = DVec3::from_array(other.center) - DVec3::from_array(me.center);
        axes.into_iter().all(|axis| {
            let radius = |half: DVec3, basis: [DVec3; 3]| {
                half.x * basis[0].dot(axis).abs()
                    + half.y * basis[1].dot(axis).abs()
                    + half.z * basis[2].dot(axis).abs()
            };
            distance.dot(axis).abs() <= radius(me.half, a) + radius(other.half, b) + 1e-9
        })
    }
    fn reference_sweep(bounds: &Bounds, position: [f64; 3], delta: [f64; 3]) -> Option<(f64, DVec3)> {
        let relative = DVec3::from_array(position) + DVec3::Y * (HEIGHT * 0.5)
            - DVec3::from_array(bounds.center);
        let movement = DVec3::from_array(delta);
        let mut enter: f64 = 0.0;
        let mut exit: f64 = 1.0;
        let mut normal = DVec3::ZERO;
        for axis in reference_axes(bounds.rotation) {
            let distance = relative.dot(axis);
            let speed = movement.dot(axis);
            let radius = bounds.radius(axis);
            if speed.abs() < 1e-12 {
                if distance.abs() >= radius - 1e-9 {
                    return None;
                }
            } else {
                let a = (-radius - distance) / speed;
                let b = (radius - distance) / speed;
                let near = a.min(b);
                exit = exit.min(a.max(b));
                if near >= enter {
                    enter = near;
                    normal = -speed.signum() * axis;
                }
                if enter > exit {
                    return None;
                }
            }
        }
        if exit < 0.0 || enter > 1.0 || normal == DVec3::ZERO {
            None
        } else {
            Some((enter, normal))
        }
    }
    fn reference_penetration(bounds: &Bounds, position: [f64; 3]) -> Option<DVec3> {
        let relative = DVec3::from_array(position) + DVec3::Y * (HEIGHT * 0.5)
            - DVec3::from_array(bounds.center);
        let mut best: Option<DVec3> = None;
        for axis in reference_axes(bounds.rotation) {
            let distance = relative.dot(axis);
            let depth = bounds.radius(axis) - distance.abs();
            if depth <= 1e-9 {
                return None;
            }
            let normal = if distance < 0.0 { -axis } else { axis };
            let push = normal * (depth + SKIN);
            if position[1] + push.y < -SKIN {
                continue;
            }
            if best.is_none_or(|b| push.length_squared() < b.length_squared()) {
                best = Some(push);
            }
        }
        best
    }
    struct Rng(u64);
    impl Rng {
        fn next(&mut self) -> f64 {
            self.0 = self.0.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
            ((self.0 >> 11) as f64) / (1u64 << 53) as f64
        }
        fn range(&mut self, lo: f64, hi: f64) -> f64 {
            lo + (hi - lo) * self.next()
        }
        fn rotation(&mut self) -> DQuat {
            DQuat::from_euler(
                glam::EulerRot::YXZ,
                self.range(-3.2, 3.2),
                self.range(-3.2, 3.2),
                self.range(-3.2, 3.2),
            )
        }
        fn bounds(&mut self) -> Bounds {
            Bounds {
                address: Address::default(),
                center: [self.range(-3.0, 3.0), self.range(0.0, 3.0), self.range(-3.0, 3.0)],
                rotation: self.rotation(),
                scale: [1.0, 1.0, 1.0],
                half: DVec3::new(self.range(0.1, 1.5), self.range(0.1, 1.5), self.range(0.1, 1.5)),
                solid: true,
            }
        }
    }

    #[test]
    fn collision_queries_match_the_allocating_reference_implementations() {
        let mut rng = Rng(0x5eed_cafe);
        // Axis-aligned rotations included: cross products vanish
        // there, which is where the two constructions could drift.
        let mut rotations = vec![DQuat::IDENTITY, DQuat::from_rotation_y(std::f64::consts::FRAC_PI_2)];
        for _ in 0..200 {
            rotations.push(rng.rotation());
        }
        for rotation in &rotations {
            let bounds = Bounds {
                address: Address::default(),
                center: [0.0; 3],
                rotation: *rotation,
                scale: [1.0; 3],
                half: DVec3::splat(0.5),
                solid: true,
            };
            let (axes, len) = bounds.axes();
            assert_eq!(&axes[..len], &reference_axes(*rotation)[..]);
        }
        for _ in 0..600 {
            let a = rng.bounds();
            let b = rng.bounds();
            assert_eq!(a.intersects(&b), reference_intersects(&a, &b));
            assert_eq!(b.intersects(&a), reference_intersects(&b, &a));
            let position = [rng.range(-3.0, 3.0), rng.range(0.0, 3.0), rng.range(-3.0, 3.0)];
            let delta = [rng.range(-2.0, 2.0), rng.range(-1.0, 1.0), rng.range(-2.0, 2.0)];
            assert_eq!(a.sweep(position, delta), reference_sweep(&a, position, delta));
            assert_eq!(a.penetration(position), reference_penetration(&a, position));
        }
    }

    #[test]
    fn standing_character_rides_moved_platform_and_falls_when_deleted() {
        let mut m = model([0.0, 0.75, 0.0], [0.0, 1.5, 0.0]);
        step(&mut m, PlayerInput::default());
        let mut s = m.snapshot();
        s.objects[0].world_position = [1.0, 0.75, 0.0];
        s.objects[0]
            .fields
            .iter_mut()
            .find(|f| f.id == "position")
            .unwrap()
            .value = serde_json::json!([1.0, 0.75, 0.0]);
        m.restore(s).unwrap();
        step(&mut m, PlayerInput::default());
        assert!((position(&m)[0] - 1.0).abs() < 0.001);
        let mut s = m.snapshot();
        s.objects.clear();
        m.restore(s).unwrap();
        for _ in 0..20 {
            step(&mut m, PlayerInput::default());
        }
        assert!(position(&m)[1] < 1.0);
    }
}
