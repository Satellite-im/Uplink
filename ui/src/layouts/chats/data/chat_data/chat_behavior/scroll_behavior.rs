use serde::{Deserialize, Serialize};
use uuid::Uuid;

#[derive(Clone, Debug, Eq, PartialEq, Deserialize, Serialize)]
pub enum ScrollBehavior {
    FetchMore,
    DoNothing,
}
