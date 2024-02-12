use dioxus::prelude::ScopeId;
use serde::{Deserialize, Serialize};

#[derive(Clone, Default, Debug, Deserialize, Serialize)]
pub struct ScopeIds {
    #[serde(skip)]
    pub chatbar: Option<usize>,
    #[serde(skip)]
    pub file_transfer: Option<usize>,
    #[serde(skip)]
    pub file_transfer_icon: Option<usize>,
    #[serde(skip)]
    pub pending_message_component: Option<usize>,
}

impl ScopeIds {
    pub fn scope_id_from_usize(scope_usize: usize) -> ScopeId {
        ScopeId(scope_usize)
    }
}
