use dioxus::prelude::*;
use uuid::Uuid;

#[derive(PartialEq, Props)]
pub struct ChatProps {
    pub show_rename_group: UseState<bool>,
    pub show_group_settings: UseState<bool>,
    pub show_manage_members: UseState<Option<Uuid>>,
    pub show_group_users: UseState<Option<Uuid>>,
    pub ignore_focus: bool,
    pub is_owner: bool,
}
