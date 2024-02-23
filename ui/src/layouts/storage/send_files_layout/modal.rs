use dioxus::prelude::*;
use kit::layout::modal::Modal;
use uuid::Uuid;
use warp::raygun::Location;

use crate::layouts::storage::send_files_layout::{SendFilesLayout, SendFilesStartLocation};

#[derive(Props)]
pub struct SendFilesLayoutModalProps<'a> {
    send_files_from_storage: &'a UseState<bool>,
    send_files_start_location: SendFilesStartLocation,
    files_pre_selected_to_send: Option<Vec<Location>>,
    on_send: EventHandler<(Vec<Location>, Vec<Uuid>)>,
}

#[allow(non_snake_case)]
pub fn SendFilesLayoutModal<'a>(props: SendFilesLayoutModalProps<'a>) -> Element {
    let send_files_from_storage = props.send_files_from_storage;
    let send_files_start_location = props.send_files_start_location.clone();
    let files_pre_selected_to_send = cx
        .props
        .files_pre_selected_to_send
        .clone()
        .unwrap_or_default();

    if !*send_files_from_storage.get() {
        return None;
    }

    rsx!( div {
                class: "send-files-to-several-chats-div",
                Modal {
                    open: *send_files_from_storage.clone(),
                    transparent: false,
                    onclose: move |_| send_files_from_storage.set(false),
                    div {
                        class: "modal-div-files-layout",
                        SendFilesLayout {
                            send_files_start_location: send_files_start_location,
                            send_files_from_storage_state: send_files_from_storage.clone(),
                            files_pre_selected_to_send: files_pre_selected_to_send,
                            on_files_attached: move |(files_location, convs_id): (Vec<Location>, Vec<Uuid>)| {
                                props.on_send.call((files_location, convs_id));
                                send_files_from_storage.set(false);
                            },
                        }
                    }
                }
            }
        )
    )
}
