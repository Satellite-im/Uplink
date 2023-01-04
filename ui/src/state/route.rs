use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
pub struct Route {
    // String representation of the current active route.
    #[serde(default)]
    pub active: To,
}

/// Alias for the type representing a route.
pub type To = String;
