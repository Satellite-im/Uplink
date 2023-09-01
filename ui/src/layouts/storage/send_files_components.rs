use std::path::PathBuf;

use common::{language::get_local_text_args_builder, MAX_FILES_PER_MESSAGE};
use dioxus::prelude::*;
use kit::elements::{button::Button, checkbox::Checkbox, Appearance};
use uuid::Uuid;

use crate::layouts::storage::ChanCmd;

#[inline_props]
pub fn file_checkbox(
    cx: Scope<'a>,
    file_path: String,
    files_selected_to_send: UseRef<Vec<String>>,
    select_files_to_send_mode: UseState<bool>,
) -> Element<'a> {
    if *select_files_to_send_mode.get() {
        return cx.render(rsx!( div {
            class: "checkbox-position",
            Checkbox {
                disabled: files_selected_to_send.read().len() >= MAX_FILES_PER_MESSAGE,
                width: "1em".into(),
                height: "1em".into(),
                is_checked: files_selected_to_send.read().contains(&file_path.clone()),
                on_click: move |_| {
                    add_remove_file_to_send(files_selected_to_send.clone(), file_path.clone());
                }
            }
        },));
    }
    None
}

#[inline_props]
pub fn send_files_from_chat_topbar(
    cx: Scope<'a>,
    ch: Coroutine<ChanCmd>,
    files_selected_to_send: UseRef<Vec<String>>,
    chat_id: Uuid,
    select_files_to_send_mode: UseState<bool>,
) -> Element<'a> {
    if *select_files_to_send_mode.get() {
        return cx.render(rsx! (div {
            class: "send-files-top-stripe",
            div {
                class: "send-files-button",
                Button {
                    text: get_local_text_args_builder("files.send-files-text-amount", |m| {
                        m.insert("amount", format!("{}/{}", files_selected_to_send.read().len(), MAX_FILES_PER_MESSAGE).into());
                    }),
                    aria_label: "send_files_modal_send_button".into(),
                    appearance: Appearance::Success,
                    onpress: move |_| {
                        ch.send(ChanCmd::SendFileToChat {
                            files_path: files_selected_to_send.read().clone()
                            .into_iter()
                            .map(PathBuf::from)
                            .collect(),
                            conversation_id: *chat_id });
                            select_files_to_send_mode.set(false);
                    }
                },
            }
            p {
                class: "files-selected-text",
                get_local_text_args_builder("files.files-selected-paths", |m| {
                    m.insert("files_path", files_selected_to_send.read().join(", ").into());
                })
            }
        }));
    }
    None
}

pub fn add_remove_file_to_send(files_selected_to_send: UseRef<Vec<String>>, file_path: String) {
    let mut files_selected = files_selected_to_send.write();
    if let Some(index) = files_selected
        .iter()
        .position(|path| path.clone() == file_path.clone())
    {
        files_selected.remove(index);
    } else if files_selected.len() < MAX_FILES_PER_MESSAGE {
        files_selected.push(file_path.clone());
    }
}
