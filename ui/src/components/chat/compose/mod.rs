mod chatbar;
mod messages;
mod quick_profile;

use std::{path::PathBuf, rc::Rc, time::Duration};

use dioxus::prelude::*;

use kit::{
    components::{
        indicator::Platform, message_group::MessageGroupSkeletal, user_image::UserImage,
        user_image_group::UserImageGroup,
    },
    elements::{
        button::Button,
        tooltip::{ArrowPosition, Tooltip},
        Appearance,
    },
    layout::topbar::Topbar,
};

use common::icons::outline::Shape as Icon;
use common::state::{ui, Action, Chat, Identity, State};

use common::language::get_local_text;
use dioxus_desktop::{use_window, DesktopContext};

#[cfg(target_os = "windows")]
use tokio::time::sleep;

use warp::{logging::tracing::log, raygun::ConversationType};
use wry::webview::FileDropEvent;

use crate::{
    components::media::player::MediaPlayer,
    layouts::storage::{
        decoded_pathbufs, get_drag_event, verify_if_there_are_valid_paths, ANIMATION_DASH_SCRIPT,
        FEEDBACK_TEXT_SCRIPT,
    },
    utils::build_participants,
};

pub const SELECT_CHAT_BAR: &str = r#"
    var chatBar = document.getElementsByClassName('chatbar')[0].getElementsByClassName('input_textarea')[0]
    chatBar.focus()
"#;

pub struct ComposeData {
    active_chat: Chat,
    my_id: Identity,
    other_participants: Vec<Identity>,
    active_participant: Identity,
    subtext: String,
    is_favorite: bool,
    first_image: String,
    other_participants_names: String,
    active_media: bool,
    platform: Platform,
}

impl PartialEq for ComposeData {
    fn eq(&self, _other: &Self) -> bool {
        false
    }
}

#[derive(PartialEq, Props)]
pub struct ComposeProps {
    #[props(!optional)]
    data: Option<Rc<ComposeData>>,
    upload_files: Option<UseState<Vec<PathBuf>>>,
}

#[allow(non_snake_case)]
pub fn Compose(cx: Scope) -> Element {
    log::trace!("rendering compose");
    let state = use_shared_state::<State>(cx)?;
    let data = get_compose_data(cx);
    let data2 = data.clone();
    let drag_event: &UseRef<Option<FileDropEvent>> = use_ref(cx, || None);
    let window = use_window(cx);
    let overlay_script = include_str!("../overlay.js");

    let files_to_upload = use_state(cx, Vec::new);

    state.write_silent().ui.current_layout = ui::Layout::Compose;
    if state.read().chats().active_chat_has_unreads() {
        state.write().mutate(Action::ClearActiveUnreads);
    }
    #[cfg(target_os = "windows")]
    use_future(cx, (), |_| {
        to_owned![files_to_upload, overlay_script, window, drag_event];
        async move {
            // ondragover function from div does not work on windows
            loop {
                sleep(Duration::from_millis(100)).await;
                if let FileDropEvent::Hovered(_) = get_drag_event() {
                    let new_files =
                        drag_and_drop_function(&window, &drag_event, overlay_script.clone()).await;
                    let mut new_files_to_upload: Vec<_> = files_to_upload
                        .current()
                        .iter()
                        .filter(|file_name| !new_files.contains(file_name))
                        .cloned()
                        .collect();
                    new_files_to_upload.extend(new_files);
                    files_to_upload.set(new_files_to_upload);
                }
            }
        }
    });

    cx.render(rsx!(
        div {
            id: "compose",
            ondragover: move |_| {
                if drag_event.with(|i| i.clone()).is_none() {
                    cx.spawn({
                        to_owned![files_to_upload, drag_event, window, overlay_script];
                        async move {
                           let new_files = drag_and_drop_function(&window, &drag_event, overlay_script).await;
                            let mut new_files_to_upload: Vec<_> = files_to_upload
                                .current()
                                .iter()
                                .filter(|file_name| !new_files.contains(file_name))
                                .cloned()
                                .collect();
                            new_files_to_upload.extend(new_files);
                            files_to_upload.set(new_files_to_upload);
                        }
                    });
                }
            },
            div {
                id: "overlay-element",
                class: "overlay-element",
                div {id: "dash-element", class: "dash-background active-animation"},
                p {id: "overlay-text0", class: "overlay-text"},
                p {id: "overlay-text", class: "overlay-text"}
            },
            Topbar {
                with_back_button: state.read().ui.is_minimal_view() || state.read().ui.sidebar_hidden,
                onback: move |_| {
                    let current = state.read().ui.sidebar_hidden;
                    state.write().mutate(Action::SidebarHidden(!current));
                },
                controls: cx.render(rsx!(get_controls{data: data2})),
                get_topbar_children{data: data.clone()}
            },
            data.as_ref().and_then(|data| data.active_media.then(|| rsx!(
                MediaPlayer {
                    settings_text: get_local_text("settings.settings"), 
                    enable_camera_text: get_local_text("media-player.enable-camera"),
                    fullscreen_text: get_local_text("media-player.fullscreen"),
                    popout_player_text: get_local_text("media-player.popout-player"),
                    screenshare_text: get_local_text("media-player.screenshare"),
                    end_text: get_local_text("uplink.end"),
                },
            ))),
            match data.as_ref() {
                None => rsx!(
                    div {
                        id: "messages",
                        MessageGroupSkeletal {},
                        MessageGroupSkeletal { alt: true }
                    }
                ),
                Some(data) =>  rsx!(messages::get_messages{data: data.clone()}),
            },
            chatbar::get_chatbar {
                data: data,
                upload_files: files_to_upload.clone()
            }
        }
    ))
}

fn get_compose_data(cx: Scope) -> Option<Rc<ComposeData>> {
    let state = use_shared_state::<State>(cx)?;
    let s = state.read();
    // the Compose page shouldn't be called before chats is initialized. but check here anyway.
    if !s.chats().initialized {
        return None;
    }

    let active_chat = match s.get_active_chat() {
        Some(c) => c,
        None => return None,
    };
    let participants = s.chat_participants(&active_chat);
    // warning: if a friend changes their username, if state.friends is updated, the old username would still be in state.chats
    // this would be "fixed" the next time uplink starts up
    let other_participants: Vec<Identity> = s.remove_self(&participants);
    let active_participant = other_participants
        .first()
        .cloned()
        .expect("chat should have at least 2 participants");

    let subtext = match active_chat.conversation_type {
        ConversationType::Direct => active_participant.status_message().unwrap_or_default(),
        _ => String::new(),
    };
    let is_favorite = s.is_favorite(&active_chat);

    let first_image = active_participant.profile_picture();
    let other_participants_names = State::join_usernames(&other_participants);
    let active_media = Some(active_chat.id) == s.chats().active_media;

    // TODO: Pending new message divider implementation
    // let _new_message_text = LOCALES
    //     .lookup(&*APP_LANG.read(), "messages.new")
    //     .unwrap_or_default();

    let platform = active_participant.platform().into();

    let data = Rc::new(ComposeData {
        active_chat,
        other_participants,
        my_id: s.get_own_identity(),
        active_participant,
        subtext,
        is_favorite,
        first_image,
        other_participants_names,
        active_media,
        platform,
    });

    Some(data)
}

fn get_controls(cx: Scope<ComposeProps>) -> Element {
    let state = use_shared_state::<State>(cx)?;
    let desktop = use_window(cx);
    let data = &cx.props.data;
    let active_chat = data.as_ref().map(|x| &x.active_chat);
    let favorite = data.as_ref().map(|d| d.is_favorite).unwrap_or_default();
    cx.render(rsx!(
        Button {
            icon: if favorite {
                Icon::HeartSlash
            } else {
                Icon::Heart
            },
            disabled: data.is_none(),
            aria_label: get_local_text(if favorite {
                "favorites.remove"
            } else {
                "favorites.favorites"
            }),
            appearance: if favorite {
                Appearance::Primary
            } else {
                Appearance::Secondary
            },
            tooltip: cx.render(rsx!(Tooltip {
                arrow_position: ArrowPosition::Top,
                text: if favorite {
                    get_local_text("favorites.remove")
                } else {
                    get_local_text("favorites.add")
                }
            })),
            onpress: move |_| {
                if let Some(chat) = active_chat.as_ref() {
                    state.write().mutate(Action::ToggleFavorite(&chat.id));
                }
            }
        },
        Button {
            icon: Icon::PhoneArrowUpRight,
            disabled: true,
            aria_label: "Call".into(),
            appearance: Appearance::Secondary,
            tooltip: cx.render(rsx!(Tooltip {
                arrow_position: ArrowPosition::Top,
                text: get_local_text("uplink.coming-soon")
            })),
            onpress: move |_| {
                if let Some(chat) = active_chat.as_ref() {
                    state
                        .write_silent()
                        .mutate(Action::ClearCallPopout(desktop.clone()));
                    state.write_silent().mutate(Action::DisableMedia);
                    state.write().mutate(Action::SetActiveMedia(chat.id));
                }
            }
        },
        Button {
            icon: Icon::VideoCamera,
            disabled: true,
            aria_label: "Videocall".into(),
            appearance: Appearance::Secondary,
            tooltip: cx.render(rsx!(Tooltip {
                arrow_position: ArrowPosition::TopRight,
                text: get_local_text("uplink.coming-soon"),
            })),
        },
    ))
}

fn get_topbar_children(cx: Scope<ComposeProps>) -> Element {
    let data = cx.props.data.clone();

    let data = match data {
        Some(d) => d,
        None => {
            return cx.render(rsx!(
                UserImageGroup {
                    loading: true,
                    participants: vec![]
                },
                div {
                    class: "user-info",
                    aria_label: "user-info",
                    div {
                        class: "skeletal-bars",
                        div {
                            class: "skeletal skeletal-bar",
                        },
                        div {
                            class: "skeletal skeletal-bar",
                        },
                    }
                }
            ))
        }
    };

    let conversation_title = match data.active_chat.conversation_name.as_ref() {
        Some(n) => n.clone(),
        None => data.other_participants_names.clone(),
    };
    let subtext = data.subtext.clone();

    cx.render(rsx!(
        if data.active_chat.conversation_type == ConversationType::Direct {rsx! (
            UserImage {
                loading: false,
                platform: data.platform,
                status: data.active_participant.identity_status().into(),
                image: data.first_image.clone(),
            }
        )} else {rsx! (
            UserImageGroup {
                loading: false,
                participants: build_participants(&data.other_participants),
            }
        )}
        div {
            class: "user-info",
            aria_label: "user-info",
            p {
                class: "username",
                "{conversation_title}"
            },
            p {
                class: "status",
                "{subtext}"
            }
        }
    ))
}

// Like ui::src:layout::storage::drag_and_drop_function
async fn drag_and_drop_function(
    window: &DesktopContext,
    drag_event: &UseRef<Option<FileDropEvent>>,
    overlay_script: String,
) -> Vec<PathBuf> {
    *drag_event.write_silent() = Some(get_drag_event());
    let mut new_files_to_upload = Vec::new();
    loop {
        let file_drop_event = get_drag_event();
        match file_drop_event {
            FileDropEvent::Hovered(files_local_path) => {
                if verify_if_there_are_valid_paths(&files_local_path) {
                    let mut script = overlay_script.replace("$IS_DRAGGING", "true");
                    if files_local_path.len() > 1 {
                        script.push_str(&FEEDBACK_TEXT_SCRIPT.replace(
                            "$TEXT",
                            &format!(
                                "{} {}!",
                                files_local_path.len(),
                                get_local_text("files.files-to-upload")
                            ),
                        ));
                    } else {
                        script.push_str(&FEEDBACK_TEXT_SCRIPT.replace(
                            "$TEXT",
                            &format!(
                                "{} {}!",
                                files_local_path.len(),
                                get_local_text("files.one-file-to-upload")
                            ),
                        ));
                    }
                    window.eval(&script);
                }
            }
            FileDropEvent::Dropped(files_local_path) => {
                if verify_if_there_are_valid_paths(&files_local_path) {
                    *drag_event.write_silent() = None;
                    new_files_to_upload = decoded_pathbufs(files_local_path);
                    let mut script = overlay_script.replace("$IS_DRAGGING", "false");
                    script.push_str(ANIMATION_DASH_SCRIPT);
                    script.push_str(SELECT_CHAT_BAR);
                    window.set_focus();
                    window.eval(&script);
                    break;
                }
            }
            _ => {
                *drag_event.write_silent() = None;
                let script = overlay_script.replace("$IS_DRAGGING", "false");
                window.eval(&script);
                break;
            }
        };
        tokio::time::sleep(std::time::Duration::from_millis(100)).await;
    }
    *drag_event.write_silent() = None;
    new_files_to_upload
}
