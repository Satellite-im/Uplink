use common::icons::outline::Shape as Icon;
use common::language::get_local_text_with_args;
use common::MAX_FILES_PER_MESSAGE;
use dioxus::prelude::*;
use kit::elements::{button::Button, checkbox::Checkbox, Appearance};
use warp::raygun::Location;

use crate::layouts::storage::files_layout::controller::StorageController;

#[component]
pub fn FileCheckbox(
    cx: Scope<'a>,
    file_path: String,
    storage_controller: UseRef<StorageController>,
    is_selecting_files: bool,
) -> Element<'a> {
    if *is_selecting_files {
        let files_selected_to_send = storage_controller.with(|f| f.files_selected_to_send.clone());
        return cx.render(rsx!( div {
            class: "checkbox-position",
            Checkbox {
                disabled: files_selected_to_send.len() >= MAX_FILES_PER_MESSAGE,
                is_checked: files_selected_to_send.iter()
                .any(|location| {
                    match location {
                        Location::Constellation { path } => path == file_path,
                        Location::Disk { .. } => false,
                    }
                }),
                on_click: move |_| {}
            }
        },));
    }
    None
}

#[component]
pub fn SendFilesTopbar<'a>(
    cx: Scope<'a>,
    storage_controller: UseRef<StorageController>,
    on_send: EventHandler<'a, Vec<Location>>,
) -> Element<'a> {
    return cx.render(rsx! (
            div {
                class: "send-files-button",
                Button {
                    text: "Go to Files".into(),
                    icon: Icon::FolderPlus,
                    disabled: true,
                    aria_label: "go_to_files_btn".into(),
                    appearance: Appearance::Secondary,
                    onpress: move |_| {
                        // TODO: Add navigation to FilesLayout 
                    },
                },
                Button {
                    text: get_local_text_with_args("files.send-files-text-amount", vec![("amount", format!("{}/{}", storage_controller.with(|f| f.files_selected_to_send.clone()).len(), MAX_FILES_PER_MESSAGE).into())]),
                    aria_label: "send_files_modal_send_button".into(),
                    disabled: storage_controller.with(|f| f.files_selected_to_send.clone()).is_empty(),
                    appearance: Appearance::Primary,
                    icon: Icon::ChevronRight,
                    onpress: move |_| {
                        on_send.call(storage_controller.with(|f| f.files_selected_to_send.clone()));
                    }
                },
            }
        ));
}

pub fn toggle_selected_file(storage_controller: UseRef<StorageController>, file_path: String) {
    if let Some(index) = storage_controller.with(|f| {
        f.files_selected_to_send
            .iter()
            .position(|location| match location {
                Location::Constellation { path } => path.eq(&file_path),
                _ => false,
            })
    }) {
        storage_controller.with_mut(|f| f.files_selected_to_send.remove(index));
    } else if storage_controller.with(|f| f.files_selected_to_send.len() < MAX_FILES_PER_MESSAGE) {
        storage_controller.with_mut(|f| {
            f.files_selected_to_send.push(Location::Constellation {
                path: file_path.clone(),
            })
        });
    }
}
