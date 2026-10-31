use crate::Address;
use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq, Hash)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum TypedReference {
    Slot { target: Address },
    Component { target: Address },
    Field { target: Address, field_id: String },
}
impl TypedReference {
    pub fn target(&self) -> &Address {
        match self {
            Self::Slot { target } | Self::Component { target } | Self::Field { target, .. } => {
                target
            }
        }
    }
}

/// Where a pinned panel sits inside its owner's window.
/// `rect` is x, y, width, height in 0..1 with the origin at the top-left.
/// `aspect` is the owner window's width divided by its height.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct ScreenRect {
    pub rect: [f64; 4],
    pub aspect: f64,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct PanelAttachment {
    pub user_id: String,
    pub offset: [f64; 3],
    pub rotation: [f64; 4],
    /// Set while the owner is viewing this panel as 2D. Others see the same
    /// panel on that person's view plane, at the matching window position.
    #[serde(default)]
    pub screen: Option<ScreenRect>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct WorldPanel {
    pub size: [u32; 2],
    pub attachment: Option<PanelAttachment>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct CreationView {
    pub shape: crate::PrimitiveShape,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct InspectorView {
    pub target: Option<Address>,
    pub scroll: [f64; 2],
    #[serde(default)]
    pub scripts_open: bool,
    #[serde(default)]
    pub script_id: Option<String>,
    #[serde(default)]
    pub tree: InspectorTree,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq)]
pub struct InspectorTree {
    pub root: Option<Address>,
    pub collapsed: Vec<Address>,
}
