use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::io;
mod scripts;
pub use scripts::*;
mod panels;
pub use panels::*;
mod replication;
pub use replication::*;
mod library;
pub use library::*;
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};

pub const MAX_FRAME: usize = 1024 * 1024;
pub const VERSION: u32 = 3;

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct AvatarPose {
    pub position: [f64; 3],
    pub yaw: f64,
    pub pitch: f64,
}

/// Camera-relative intent. Position and velocity are computed by the local Engine.
#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq)]
pub struct PlayerInput {
    pub movement: [f64; 2],
    pub yaw: f64,
    pub pitch: f64,
    pub jump: bool,
    pub face_view: bool,
    pub active: bool,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq)]
pub struct CharacterState {
    pub velocity: [f64; 3],
    pub grounded: bool,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct ParticipantView {
    pub id: String,
    pub name: String,
    pub pose: AvatarPose,
    #[serde(default)]
    pub avatar_texture: Option<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct SessionChatMessage {
    pub id: String,
    pub sender_id: String,
    pub sender_name: String,
    pub text: String,
    pub at_millis: u64,
}

pub fn valid_asset_id(id: &str) -> bool {
    id.len() == 64
        && id
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq, Eq, Hash)]
pub struct Address {
    pub instance_id: String,
    pub local_id: u32,
}

/// Temporary editor display state; never part of a persistent world snapshot.
#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq)]
pub struct ObjectPreview {
    pub target: Address,
    pub expected_revision: String,
    pub position: [f64; 3],
    #[serde(default)]
    pub rotation: Option<[f64; 4]>,
    #[serde(default)]
    pub scale: Option<[f64; 3]>,
    #[serde(default)]
    pub expected_rotation_revision: Option<String>,
    #[serde(default)]
    pub expected_scale_revision: Option<String>,
}

pub fn identity_rotation() -> [f64; 4] {
    [0.0, 0.0, 0.0, 1.0]
}
pub fn unit_scale() -> [f64; 3] {
    [1.0; 3]
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct ColliderSpec {
    pub half_extents: [f64; 3],
    pub solid: bool,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct GrabView {
    pub preview: ObjectPreview,
    pub distance: f64,
    pub released: bool,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct InteractionRay {
    pub origin: [f64; 3],
    pub point: [f64; 3],
    pub target: Option<Address>,
    pub holding: bool,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct Field {
    pub component_id: u32,
    pub id: String,
    pub label: String,
    pub value_type: String,
    pub revision: String,
    pub value: Value,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct VideoPlayback {
    pub playing: bool,
    pub looping: bool,
    pub position_seconds: f64,
    pub anchor_seconds: f64,
}
impl VideoPlayback {
    pub fn position_at(&self, now: f64, duration: f64) -> f64 {
        let position = self.position_seconds
            + if self.playing {
                (now - self.anchor_seconds).max(0.0)
            } else {
                0.0
            };
        if duration > 0.0 {
            if self.looping {
                position.rem_euclid(duration)
            } else {
                position.min(duration)
            }
        } else {
            position
        }
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct PlaybackCommand {
    pub command_id: String,
    pub target: Address,
    pub expected_revision: String,
    #[serde(flatten)]
    pub action: PlaybackAction,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(tag = "action", rename_all = "snake_case")]
pub enum PlaybackAction {
    Play,
    Pause,
    Restart,
    Seek { position_seconds: f64 },
    Loop { looping: bool },
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct ObjectView {
    #[serde(default)]
    pub parent: Option<Address>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub item_identity: Option<ItemIdentity>,
    pub address: Address,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub renderer: Option<Address>,
    pub object_revision: String,
    pub world_position: [f64; 3],
    #[serde(default = "identity_rotation")]
    pub world_rotation: [f64; 4],
    #[serde(default = "unit_scale")]
    pub world_scale: [f64; 3],
    #[serde(default)]
    pub collider: Option<ColliderSpec>,
    #[serde(default)]
    pub visual: Visual,
    #[serde(default)]
    pub playback: Option<VideoPlayback>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub scripts: Vec<ScriptComponent>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub panel: Option<WorldPanel>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub inspector: Option<InspectorView>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub creation: Option<CreationView>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub resources: Option<ResourcesView>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub script_editor: Option<ScriptEditorView>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub world_text: Option<WorldText>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub mirror: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub camera: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub value_number: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub value_bool: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub value_text: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub button: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub contact_sensor: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub planar_motion: Option<PlanarMotionSpec>,
    pub fields: Vec<Field>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct PlanarMotionSpec {
    pub enabled: bool,
    /// Metres per second in the world X/Z plane; Y is always zero.
    pub velocity: [f64; 3],
    pub drag: f64,
    pub bounce: f64,
    /// World-space [min_x, max_x, min_z, max_z].
    pub bounds: [f64; 4],
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct WorldText {
    pub text: String,
    pub color: [f64; 4],
}

#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Visual {
    None,
    #[default]
    Cube,
    Primitive { shape: PrimitiveShape },
    Panel,
    Image {
        data_url: String,
        width: u32,
        height: u32,
    },
    Model {
        asset_id: String,
        half_extents: [f64; 3],
    },
    Video {
        asset_id: String,
        width: u32,
        height: u32,
        #[serde(default)]
        duration_seconds: f64,
    },
}

#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum PrimitiveShape {
    Box,
    Sphere,
    Capsule,
    Cylinder,
    Cone,
    Torus,
    Grid,
    Quad,
    Camera,
    Mirror,
}

impl PrimitiveShape {
    pub fn half_extents(self) -> [f64; 3] {
        match self {
            Self::Capsule => [0.375, 0.75, 0.375],
            Self::Torus => [0.75, 0.2, 0.75],
            Self::Grid => [0.75, 0.025, 0.75],
            Self::Quad => [0.75, 0.75, 0.025],
            Self::Camera => [0.4, 0.25, 0.45],
            Self::Mirror => [1.0, 1.0, 0.05],
            _ => [0.75; 3],
        }
    }
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct Snapshot {
    pub world_revision: String,
    pub objects: Vec<ObjectView>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Edit {
    pub command_id: String,
    pub target: Address,
    pub field_id: String,
    pub expected_revision: String,
    pub value: Value,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct TransformCommand {
    pub command_id: String,
    pub target: Address,
    pub expected_position_revision: String,
    pub expected_rotation_revision: String,
    pub expected_scale_revision: String,
    #[serde(default)]
    pub space: PositionSpace,
    pub position: [f64; 3],
    pub rotation: [f64; 4],
    pub scale: [f64; 3],
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct StructuralCommand {
    pub command_id: String,
    #[serde(flatten)]
    pub operation: StructuralOperation,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(tag = "action", rename_all = "snake_case")]
pub enum StructuralOperation {
    CreateSlot {
        parent: Option<Address>,
        position: [f64; 3],
        #[serde(default)]
        rotation: Option<[f64; 4]>,
        #[serde(default)]
        position_space: PositionSpace,
        #[serde(default)]
        components: Vec<InitialComponent>,
    },
    AddComponent { target: Address, type_id: String, expected_revision: String, values: Value },
    RemoveComponent { target: Address, type_id: String, expected_revision: String },
    CreateChild { parent: Address },
    Reparent { target: Address, parent: Option<Address>, expected_revision: String },
    Create,
    CreateInspector {
        target: Option<Address>,
        position: [f64; 3],
        rotation: [f64; 4],
    },
    CreateCreationPanel {
        position: [f64; 3],
        rotation: [f64; 4],
    },
    CreateResourcesPanel {
        target: Option<Address>,
        position: [f64; 3],
        rotation: [f64; 4],
    },
    CreateScriptEditorPanel {
        target: Option<Address>,
        script_id: Option<String>,
        position: [f64; 3],
        rotation: [f64; 4],
    },
    CreateImage {
        data_url: String,
    },
    ImportAsset {
        name: String,
        position: [f64; 3],
        rotation: [f64; 4],
        visual: Visual,
    },
    Duplicate {
        target: Address,
        expected_revision: String,
    },
    Delete {
        target: Address,
        expected_revision: String,
    },
}

#[derive(Clone, Copy, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PositionSpace {
    #[default]
    World,
    Parent,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct InitialComponent {
    pub type_id: String,
    pub values: Value,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum WorldCommand {
    Edit { edit: Edit },
    Transform { command: TransformCommand },
    Structure { command: StructuralCommand },
    Playback { command: PlaybackCommand },
    Script { command: ScriptCommand },
}

impl WorldCommand {
    pub fn command_id(&self) -> &str {
        match self {
            Self::Edit { edit } => &edit.command_id,
            Self::Structure { command } => &command.command_id,
            Self::Transform { command } => &command.command_id,
            Self::Playback { command } => &command.command_id,
            Self::Script { command } => &command.command_id,
        }
    }
    pub fn set_command_id(&mut self, id: String) {
        match self {
            Self::Edit { edit } => edit.command_id = id,
            Self::Structure { command } => command.command_id = id,
            Self::Transform { command } => command.command_id = id,
            Self::Playback { command } => command.command_id = id,
            Self::Script { command } => command.command_id = id,
        }
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct WorldCommit {
    pub world_revision: String,
    pub upserts: Vec<ObjectView>,
    pub removed: Vec<Address>,
}

// All revisions are decimal strings, including over JSON/GDScript boundaries.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Envelope {
    pub protocol_version: u32,
    pub session_id: String,
    pub authority_epoch: String,
    pub sequence: String,
    pub body: Value,
}

pub async fn read_frame<R: AsyncRead + Unpin>(reader: &mut R) -> io::Result<Value> {
    let len = reader.read_u32().await? as usize;
    if len == 0 || len > MAX_FRAME {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "frame size exceeded",
        ));
    }
    let mut data = vec![0; len];
    reader.read_exact(&mut data).await?;
    serde_json::from_slice(&data).map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))
}

pub async fn write_frame<W: AsyncWrite + Unpin>(writer: &mut W, value: &Value) -> io::Result<()> {
    let data = serde_json::to_vec(value)?;
    if data.len() > MAX_FRAME {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "frame size exceeded",
        ));
    }
    writer.write_u32(data.len() as u32).await?;
    writer.write_all(&data).await
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[tokio::test]
    async fn partial_tcp_reads_preserve_message_boundaries() {
        let (mut writer, mut reader) = tokio::io::duplex(32);
        let expected = json!({"label":"共同編集", "revision":"9007199254740993",
            "rotation":[0.0,0.2657920358400604,0.0,0.9640303904359013]});
        let bytes = serde_json::to_vec(&expected).unwrap();
        let task = tokio::spawn(async move {
            let framed = [(bytes.len() as u32).to_be_bytes().as_slice(), &bytes].concat();
            for byte in framed {
                writer.write_all(&[byte]).await.unwrap();
            }
            write_frame(&mut writer, &json!({"next":true}))
                .await
                .unwrap();
        });
        assert_eq!(read_frame(&mut reader).await.unwrap(), expected);
        assert_eq!(read_frame(&mut reader).await.unwrap(), json!({"next":true}));
        task.await.unwrap();
    }

    #[tokio::test]
    async fn oversized_frame_is_rejected_without_reading_body() {
        let (mut writer, mut reader) = tokio::io::duplex(4);
        writer.write_u32(MAX_FRAME as u32 + 1).await.unwrap();
        assert_eq!(
            read_frame(&mut reader).await.unwrap_err().kind(),
            io::ErrorKind::InvalidData
        );
    }
}
