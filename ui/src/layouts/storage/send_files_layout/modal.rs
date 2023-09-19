use common::{
    warp_runner::{RayGunCmd, WarpCmd},
    WARP_CMD_CH,
};
use dioxus::prelude::*;
use futures::channel::oneshot;
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

fn send_files_starting_on_storage(
    send_files_from_storage: UseState<bool>,
    files_location: Vec<Location>,
    convs_id: Vec<Uuid>,
) {
    let warp_cmd_tx = WARP_CMD_CH.tx.clone();
    let (tx, _) = oneshot::channel::<Result<(), warp::error::Error>>();
    let msg = vec!["".to_owned()];
    let attachments = files_location;
    let ui_msg_id = None;
    let convs_id = convs_id;
    if let Err(e) = warp_cmd_tx.send(WarpCmd::RayGun(RayGunCmd::SendMessageForSeveralChats {
        convs_id,
        msg,
        attachments,
        ui_msg_id,
        rsp: tx,
    })) {
        log::error!("Failed to send warp command: {}", e);
        return;
    }
    send_files_from_storage.set(false);
}
