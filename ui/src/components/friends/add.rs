use std::str::FromStr;

use dioxus::prelude::*;
use futures::{channel::oneshot, StreamExt};
use kit::{
    elements::{
        button::Button,
        input::{Input, Options, Validation},
        label::Label,
    },
    icons::Icon,
};
use shared::language::get_local_text;
use warp::crypto::DID;

use crate::{
    warp_runner::{commands::MultiPassCmd, WarpCmd},
    WARP_CMD_CH,
};

#[allow(non_snake_case)]
pub fn AddFriend(cx: Scope) -> Element {
    let friend_input = use_state(cx, String::new);
    let friend_input_valid = use_state(cx, || false);
    // Set up validation options for the input field
    let friend_validation = Validation {
        // The input should have a maximum length of 32
        max_length: Some(32),
        // The input should have a minimum length of 4
        min_length: Some(4),
        // The input should only contain alphanumeric characters
        alpha_numeric_only: true,
        // The input should not contain any whitespace
        no_whitespace: true,
    };

    let ch = use_coroutine(cx, |mut rx: UnboundedReceiver<DID>| async move {
        let warp_cmd_tx = WARP_CMD_CH.tx.clone();
        while let Some(did) = rx.next().await {
            let (tx, rx) = oneshot::channel::<Result<(), warp::error::Error>>();
            warp_cmd_tx
                .send(WarpCmd::MultiPass(MultiPassCmd::RequestFriend {
                    did,
                    rsp: tx,
                }))
                .expect("AddFriendLayout failed to send warp command");

            let res = rx.await.expect("failed to get response from warp_runner");
            match res {
                Ok(_) => todo!("update ui to say request was sent"),
                Err(_) => todo!("failed to send friend request"),
            }
        }
    });

    let id_ch = use_coroutine(cx, |mut rx: UnboundedReceiver<()>| async move {
        let warp_cmd_tx = WARP_CMD_CH.tx.clone();
        while let Some(_) = rx.next().await {
            println!("requesting own id");
            let (tx, rx) = oneshot::channel::<Result<DID, warp::error::Error>>();
            warp_cmd_tx
                .send(WarpCmd::MultiPass(MultiPassCmd::GetOwnIdentity { rsp: tx }))
                .expect("AddFriendLayout failed to send warp command");

            let res = rx.await.expect("failed to get response from warp_runner");
            match res {
                Ok(_) => todo!("copy to clipboard and make toast"),
                Err(_) => todo!("failed to get own identity"),
            }
        }
    });

    cx.render(rsx!(
        div {
            class: "add-friend",
            Label {
                text: get_local_text("friends.add"),
            },
            div {
                class: "body",
                Input {
                    placeholder: get_local_text("friends.placeholder"),
                    icon: Icon::MagnifyingGlass,
                    options: Options {
                        with_validation: Some(friend_validation),
                        // Do not replace spaces with underscores
                        replace_spaces_underscore: false,
                        // Show a clear button inside the input field
                        with_clear_btn: true,
                        // Use the default options for the remaining fields
                        ..Options::default()
                    },
                    onchange: |(s, is_valid)| {
                        friend_input.set(s);
                        friend_input_valid.set(is_valid);
                    }
                },
                Button {
                    icon: Icon::Plus,
                    text: get_local_text("uplink.add"),
                    disabled: !*friend_input_valid.current(),
                    onpress: move |_| {
                        println!("clicked plus");
                        match DID::from_str(&friend_input.current()) {
                            Ok(did) => ch.send(did),
                            Err(_e) => todo!("failed to convert string to DID")
                        }
                    }
                },
                // todo: verify that this is the desired UI
                Button {
                    icon: Icon::ClipboardDocument,
                    onpress: move |_| {
                        println!("clicked clipboard");
                        id_ch.send(());
                    }
                }
            }
        }
    ))
}
