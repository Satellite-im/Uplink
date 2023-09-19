use dioxus::prelude::*;
use kit::layout::modal::Modal;
use uuid::Uuid;
use warp::raygun::Location;

use crate::layouts::storage::send_files_layout::{SendFilesLayout, SendFilesStartLocation};

#[derive(Props)]
pub struct SendFilesLayoutModalProps<'a> {
    send_files_from_storage: &'a UseState<bool>,
    send_files_start_location: SendFilesStartLocation,
    on_send: EventHandler<'a, (Vec<Location>, Vec<Uuid>)>,
}

#[allow(non_snake_case)]
pub fn SendFilesLayoutModal<'a>(cx: Scope<'a, SendFilesLayoutModalProps<'a>>) -> Element<'a> {
    let send_files_from_storage = cx.props.send_files_from_storage;
    let send_files_start_location = cx.props.send_files_start_location.clone();

    if !*send_files_from_storage.get() {
        return None;
    }

    cx.render(rsx!( div {
                class: "send-files-to-several-chats-div",
                Modal {
                    open: *send_files_from_storage.clone(),
                    transparent: false,
                    onclose: move |_| send_files_from_storage.set(false),
                    div {
                        class: "modal-div-files-layout",
                        SendFilesLayout {
                            send_files_start_location: send_files_start_location,
                            on_files_attached: move |(files_location, convs_id): (Vec<Location>, Vec<Uuid>)| {
                                cx.props.on_send.call((files_location, convs_id));
                            },
                        }
                    }
                }
            }
        )
    )
}
