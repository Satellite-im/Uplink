use dioxus::prelude::*;
use uuid::Uuid;
use warp::raygun;

#[derive(PartialEq, Props)]
pub struct ChatProps {
    pub show_edit_group: UseState<Option<Uuid>>,
    pub show_group_users: UseState<Option<Uuid>>,
    pub ignore_focus: bool,
    pub is_owner: bool,
    pub is_edit_group: bool,
}

#[derive(PartialEq, Props)]
pub struct ChatBarProps {
    pub show_edit_group: UseState<Option<Uuid>>,
    pub show_group_users: UseState<Option<Uuid>>,
    pub ignore_focus: bool,
    pub is_owner: bool,
    pub replying_to: Option<raygun::Message>,
    pub chat_initialized: bool,
    pub chat_id: Option<Uuid>,
    pub other_participants: Vec<Uuid>,
}
