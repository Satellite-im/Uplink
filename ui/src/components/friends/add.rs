use arboard::Clipboard;
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
use warp::error::Error;

use crate::{
    state::{Action, State, ToastNotification},
    warp_runner::{commands::MultiPassCmd, WarpCmd},
    WARP_CMD_CH,
};
#[allow(non_snake_case)]
pub fn AddFriend(cx: Scope) -> Element {
    let state = use_shared_state::<State>(cx)?;
    let friend_input = use_state(cx, String::new);
    let friend_input_valid = use_state(cx, || false);
    let request_sent = use_state(cx, || false);
    // used when copying the user's id to the clipboard
    let my_id: &UseState<Option<String>> = use_state(cx, || None);
    // Set up validation options for the input field
    let friend_validation = Validation {
        max_length: Some(56),
        min_length: Some(56),
        alpha_numeric_only: false,
        no_whitespace: true,
    };

    // todo: add translations for toasts
    if *request_sent.get() {
        state
            .write()
            .mutate(Action::AddToastNotification(ToastNotification::init(
                "".into(),
                get_local_text("friends.request-sent"),
                None,
                5,
            )));
        request_sent.set(false);
    }

    if let Some(id) = my_id.get().clone() {
        let mut clipboard = Clipboard::new().unwrap();
        clipboard.set_text(id).unwrap();
        state
            .write()
            .mutate(Action::AddToastNotification(ToastNotification::init(
                "".into(),
                get_local_text("friends.copied-did"),
                None,
                5,
            )));
        my_id.set(None);
    }

    let ch = use_coroutine(cx, |mut rx: UnboundedReceiver<DID>| {
        to_owned![request_sent];
        async move {
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
                    Ok(_) | Err(Error::FriendRequestExist) => {
                        request_sent.set(true);
                    }
                    Err(e) => match e {
                        Error::CannotSendSelfFriendRequest
                        | Error::CannotSendFriendRequest
                        | Error::IdentityDoesntExist
                        | Error::BlockedByUser
                        | Error::InvalidIdentifierCondition
                        | Error::PublicKeyIsBlocked => {
                            // todo: show an error message
                        }
                        _ => {
                            println!("error: {:?}", e);
                            todo!("failed to send friend request");
                        }
                    },
                }
            }
        }
    });

    let id_ch = use_coroutine(cx, |mut rx: UnboundedReceiver<()>| {
        to_owned![my_id];
        async move {
            let warp_cmd_tx = WARP_CMD_CH.tx.clone();
            while rx.next().await.is_some() {
                let (tx, rx) = oneshot::channel::<Result<DID, warp::error::Error>>();
                warp_cmd_tx
                    .send(WarpCmd::MultiPass(MultiPassCmd::GetOwnDid { rsp: tx }))
                    .expect("AddFriendLayout failed to send warp command");

                let res = rx.await.expect("failed to get response from warp_runner");
                if let Ok(did) = res {
                    // todo: log error,
                    my_id.set(Some(did.to_string()));
                }
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
                    },
                    aria_label: "Add Someone Input".into()
                },
                Button {
                    icon: Icon::Plus,
                    text: get_local_text("uplink.add"),
                    disabled: !friend_input_valid.get(),
                    onpress: move |_| {
                        match DID::from_str(friend_input.get()) {
                            Ok(did) => ch.send(did),
                            Err(e) => {
                                println!("error: {}", e);
                                todo!("failed to convert string to DID");
                            }
                        }
                    },
                    aria_label: "Add Someone Button".into()
                },
                // todo: verify that this is the desired UI
                Button {
                    icon: Icon::ClipboardDocument,
                    onpress: move |_| {
                        id_ch.send(());
                    }
                }
            }
        }
    ))
}
