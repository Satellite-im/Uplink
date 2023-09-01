use crate::{utils::build_participants, UplinkRoute};
use common::icons::outline::Shape as Icon;

use common::{
    language::get_local_text,
    state::{Action, State},
};
use dioxus::prelude::*;
use dioxus_router::prelude::*;
use kit::elements::button::Button;
use kit::elements::tooltip::{ArrowPosition, Tooltip};
use kit::{
    components::{
        context_menu::{ContextItem, ContextMenu},
        user_image_group::UserImageGroup,
    },
    layout::slimbar::Slimbar,
};

#[derive(PartialEq, Props)]
pub struct Props {
    pub active: UplinkRoute,
}

#[allow(non_snake_case)]
pub fn SlimbarLayout(cx: Scope<Props>) -> Element {
    let state = use_shared_state::<State>(cx)?;
    let router = use_navigator(cx);

    let favorites = if state.read().initialized {
        state.read().chats_favorites()
    } else {
        vec![]
    };

    cx.render(rsx!(
        Slimbar { // TODO: This should hide when the sidebar is hidden if the view is minimal (mobile).
            with_back_button: !state.read().ui.is_minimal_view() && state.read().ui.sidebar_hidden,
            onback: move |_| {
                let current = state.read().ui.sidebar_hidden;
                state.write().mutate(Action::SidebarHidden(!current));
            },
            top_children: cx.render(rsx!(
                // Only display favorites if we have some.
                (!favorites.is_empty()).then(|| rsx!(
                    div {
                        id: "favorites",
                        aria_label: "Favorites",
                        favorites.iter().cloned().map(|chat| {
                            let users_typing = chat.typing_indicator.iter().any(|(k, _)| *k != state.read().did_key());
                            let favorites_chat = chat.clone();
                            let remove_favorite = chat.clone();
                            let chat_id = chat.id;
                            let participants = state.read().chat_participants(&chat);
                            let other_participants: Vec<_> = state.read().remove_self(&participants);
                            let participants_name = match chat.conversation_name {
                                Some(name) => name,
                                None => State::join_usernames(&other_participants)
                            };
                            rsx! (
                                ContextMenu {
                                    key: "{chat_id}-favorite",
                                    id: chat_id.to_string(),
                                    items: cx.render(rsx!(
                                        ContextItem {
                                            aria_label: "favorites-chat".into(),
                                            icon: Icon::ChatBubbleBottomCenterText,
                                            text: get_local_text("uplink.chat"),
                                            onpress: move |_| {
                                                if state.read().ui.is_minimal_view() {
                                                    state.write().mutate(Action::SidebarHidden(true));
                                                }
                                                state.write().mutate(Action::ChatWith(&favorites_chat.id, false));
                                                router.replace(UplinkRoute::ChatLayout{});
                                            }
                                        },
                                        ContextItem {
                                            aria_label: "favorites-remove".into(),
                                            icon: Icon::HeartSlash,
                                            text: get_local_text("favorites.remove"),
                                            onpress: move |_| {
                                                state.write().mutate(Action::ToggleFavorite(&remove_favorite.id));
                                            }
                                        }
                                    )),
                                    UserImageGroup {
                                        participants: build_participants(&other_participants),
                                        aria_label: participants_name.clone().into(),
                                        with_username: participants_name,
                                        use_tooltip: true,
                                        typing: users_typing,
                                        onpress: move |_| {
                                            if state.read().ui.is_minimal_view() {
                                                state.write().mutate(Action::SidebarHidden(true));
                                            }
                                            state.write().mutate(Action::ChatWith(&chat.id, false));
                                            router.replace(UplinkRoute::ChatLayout{});
                                        }
                                    }
                                }
                            )
                        })
                    }
                )),
            )),
            navbar_visible: state.read().ui.sidebar_hidden,
            with_nav: cx.render(rsx!(
                crate::AppNav {
                    active: cx.props.active.clone(),
                    tooltip_direction: ArrowPosition::Left,
                    onnavigate: move |_| {
                        if state.read().configuration.audiovideo.interface_sounds {
                            common::sounds::Play(common::sounds::Sounds::Interaction);
                        }
                        if state.read().ui.is_minimal_view() {
                            state.write().mutate(Action::SidebarHidden(true));
                        }
                    },
                },
            )),
            state.read().configuration.developer.experimental_features.then(|| rsx!(
                Button {
                    icon: Icon::Plus,
                    tooltip: cx.render(rsx!(
                        Tooltip {
                            arrow_position: ArrowPosition::Left,
                            text: "Create Community".into()
                        }
                    )),
                    onpress: move |_| {
                        router.replace(UplinkRoute::CommunityLayout {});
                    }
                }
            ))
        }
    ))
}
