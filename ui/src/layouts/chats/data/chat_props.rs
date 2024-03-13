use dioxus::prelude::*;
use uuid::Uuid;

#[derive(PartialEq, Props)]
pub struct ChatProps {
    pub show_rename_group: Signal<bool>,
    pub show_group_settings: Signal<bool>,
    pub show_manage_members: Signal<Option<Uuid>>,
    pub show_group_users: Signal<Option<Uuid>>,
    pub ignore_focus: bool,
    pub is_owner: bool,
}
