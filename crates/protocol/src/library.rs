use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct ItemIdentity {
    pub creator_id: String,
    pub owner_id: String,
    #[serde(default)]
    pub source_version: Option<String>,
    #[serde(default)]
    pub permissions: ItemPermissions,
    #[serde(default)]
    pub editors: Vec<ItemEditor>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct ItemEditor {
    pub user_id: String,
    pub edited_at: u64,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct ItemPermissions {
    pub modify: bool,
    pub redistribute: bool,
}

impl Default for ItemPermissions {
    fn default() -> Self {
        Self {
            modify: true,
            redistribute: false,
        }
    }
}

/// Marks the Slot range that saves / duplicates together as one work.
/// Distinct from parent/child layout. Prefab instances share `prefab_key`.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct ItemBoundary {
    /// Empty when this root is a one-off work, not a prefab template.
    #[serde(default)]
    pub prefab_key: String,
    /// When true, edits to this root apply to all instances with the same prefab_key.
    #[serde(default)]
    pub editing_prefab: bool,
}
