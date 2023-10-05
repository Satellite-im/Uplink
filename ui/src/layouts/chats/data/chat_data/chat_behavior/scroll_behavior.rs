use serde::{Deserialize, Serialize};


#[derive(Clone, Debug, Eq, PartialEq, Deserialize, Serialize)]
pub enum ScrollBehavior {
    FetchMore,
    DoNothing,
}
