use common::{state::{State, self}, language::{get_local_text, get_local_text_with_args}};
use dioxus::prelude::*;
use kit::{elements::{label::Label, checkbox::Checkbox}, components::{user::User, user_image::UserImage, user_image_group::UserImageGroup, message::markdown}};
use uuid::Uuid;
use warp::raygun::{Location, ConversationType, self};

pub mod send_files_components;
pub mod modal;

use crate::{layouts::storage::{send_files_layout::send_files_components::SendFilesTopbar, shared_component::{FilesBreadcumbs, FilesAndFolders}}, utils::build_participants};

use super::{
    files_layout::controller::StorageController,
    functions::{self, ChanCmd},
};

#[derive(PartialEq, Clone)]
pub enum SendFilesStartLocation {
    Chats,
    Storage,
}

#[derive(Props)]
pub struct SendFilesProps<'a> {
    send_files_start_location: SendFilesStartLocation,
    on_files_attached: EventHandler<'a, (Vec<Location>, Vec<Uuid>)>,
}

#[allow(non_snake_case)]
pub fn SendFilesLayout<'a>(cx: Scope<'a, SendFilesProps<'a>>) -> Element<'a> {
    let state = use_shared_state::<State>(cx)?;
    let send_files_start_location = cx.props.send_files_start_location.clone();
    let storage_controller = StorageController::new(cx, state);
    let ch: &Coroutine<ChanCmd> = functions::init_coroutine(cx, storage_controller);

    functions::get_items_from_current_directory(cx, ch);

    storage_controller
        .write_silent()
        .update_current_dir_path(state.clone());

    cx.render(rsx!(div {
        id: "send-files-layout",
        aria_label: "send-files-layout",
        div {
            class: "files-body disable-select",
            aria_label: "send-files-body",
            SendFilesTopbar {
                storage_controller: storage_controller.clone(),
                on_send: move |files_location_path| {
                    cx.props.on_files_attached.call((files_location_path, storage_controller.with(|f| f.chats_selected_to_send.clone())));
                }
            }
            if send_files_start_location.eq(&SendFilesStartLocation::Storage) {
                rsx!(ChatsToSelect {
                    storage_controller: storage_controller,
                })
            }
            FilesBreadcumbs {
                storage_controller: storage_controller, 
                ch: ch,
                send_files_mode: true,
            },
            if storage_controller.read().files_list.is_empty()
                && storage_controller.read().directories_list.is_empty() {
                    rsx!(
                        div {
                            padding: "48px",
                            Label {
                                text: get_local_text("files.no-files-available"),
                            }
                        }
                        )
               } else {
                rsx!(FilesAndFolders {
                    storage_controller: storage_controller,
                    ch: ch,
                    send_files_mode: true,
                })
               }
        }
    }))
}


#[derive(PartialEq, Props)]
struct ChatsToSelectProps<'a> {
    storage_controller: &'a UseRef<StorageController>,
}

#[allow(non_snake_case)]
fn ChatsToSelect<'a>(cx: Scope<'a, ChatsToSelectProps<'a>>) -> Element<'a> {
    let state = use_shared_state::<State>(cx)?;
    let storage_controller = cx.props.storage_controller.clone();

    cx.render(rsx!(div {
        id: "all_chats", 
        div {
            padding_left: "16px",
            Label {
                text: get_local_text("files.select-chats"),
            }
        }
        state.read().chats_sidebar().iter().cloned().map(|chat| {
            let participants = state.read().chat_participants(&chat);
            let other_participants =  state.read().remove_self(&participants);
            let user: state::Identity = other_participants.first().cloned().unwrap_or_default();
            let platform = user.platform().into();
    
            // todo: how to tell who is participating in a group chat if the chat has a conversation_name?
            let participants_name = match chat.conversation_name {
                Some(name) => name,
                None => State::join_usernames(&other_participants)
            };
            let is_checked = storage_controller.read().chats_selected_to_send.iter()
            .any(|uuid| {
                uuid.eq(&chat.id)
            });
            
            let unwrapped_message = match chat.messages.iter().last() {
                Some(m) => m.inner.clone(),
                // conversation with no messages yet
                None => raygun::Message::default(),
            };
            let subtext_val = match unwrapped_message.value().iter().map(|x| x.trim()).find(|x| !x.is_empty()) {
                Some(v) => markdown(v),
                _ => match &unwrapped_message.attachments()[..] {
                    [] => get_local_text("sidebar.chat-new"),
                    [ file ] => file.name(),
                    _ => match participants.iter().find(|p| p.did_key()  == unwrapped_message.sender()).map(|x| x.username()) {
                        Some(name) => get_local_text_with_args("sidebar.subtext", vec![("user", name.into())]),
                        None => {
                            log::error!("error calculating subtext for sidebar chat");
                            // Still return default message
                            get_local_text("sidebar.chat-new")
                        }
                    }
                }
            };

            rsx!(div {
                    id: "chat-selector-to-send-files",
                    height: "80px",
                    padding: "16px",
                    display: "inline-flex",
                    Checkbox {
                        disabled: false,
                        width: "1em".into(),
                        height: "1em".into(),
                        is_checked: is_checked,
                        on_click: move |_| {
                            if is_checked {
                                cx.props.storage_controller.with_mut(|f| f.chats_selected_to_send.retain(|uuid| chat.id != *uuid));
                            } else {
                                cx.props.storage_controller.with_mut(|f| f.chats_selected_to_send.push(chat.id));
                            }
                        }
                    }
                    User {
                        username: participants_name,
                        subtext: subtext_val,
                        timestamp: raygun::Message::default().date(),
                        active: false,
                        user_image: cx.render(rsx!(
                            if chat.conversation_type == ConversationType::Direct {rsx! (
                                UserImage {
                                    platform: platform,
                                    status:  user.identity_status().into(),
                                    image: user.profile_picture(),
                                    typing: false,
                                }
                            )} else {rsx! (
                                UserImageGroup {
                                    participants: build_participants(&participants),
                                    typing: false,
                                }
                            )}
                        )),
                        with_badge: "".into(),
                        onpress: move |_| {
                            if is_checked {
                                cx.props.storage_controller.with_mut(|f| f.chats_selected_to_send.retain(|uuid| chat.id != *uuid));
                            } else {
                                cx.props.storage_controller.with_mut(|f| f.chats_selected_to_send.push(chat.id));
                            }
                        }
                    }
                }
            )
        }),
    }))
}
