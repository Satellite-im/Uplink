use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, Eq, PartialEq, Deserialize, Serialize)]
pub struct MessageIndices {
    pub start: usize,
    pub end: usize,
}
