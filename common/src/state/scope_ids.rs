use dioxus::prelude::ScopeId;
use serde::{Deserialize, Serialize};

#[derive(Clone, Default, Debug, Deserialize, Serialize)]
pub struct ScopeIds {
    #[serde(skip)]
    pub chatbar: Option<usize>,
}

impl ScopeIds {
    pub fn scope_id_from_usize(scope_usize: usize) -> ScopeId {
        ScopeId(scope_usize)
    }
}
