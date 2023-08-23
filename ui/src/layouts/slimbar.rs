use crate::{components::chat::RouteInfo, utils::build_participants, UPLINK_ROUTES};
use common::icons::outline::Shape as Icon;

use common::{
    language::get_local_text,
    state::{Action, State},
};
use dioxus::prelude::*;
use dioxus_router::*;
use kit::{
    components::{
        context_menu::{ContextItem, ContextMenu},
        nav::Nav,
        user_image_group::UserImageGroup,
    },
    elements::tooltip::ArrowPosition,
    layout::slimbar::Slimbar,
};

#[derive(PartialEq, Props)]
pub struct Props {
    route_info: RouteInfo,
}

#[allow(non_snake_case)]
pub fn SlimbarLayout(cx: Scope<Props>) -> Element {
    let state = use_shared_state::<State>(cx)?;
    let router: &std::rc::Rc<RouterService> = use_router(cx);

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
                                                if cx.props.route_info.active.to != UPLINK_ROUTES.chat {
                                                    router.replace_route(UPLINK_ROUTES.chat, None, None);
                                                }
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
                                        with_username: participants_name,
                                        use_tooltip: true,
                                        typing: users_typing,
                                        onpress: move |_| {
                                            if state.read().ui.is_minimal_view() {
                                                state.write().mutate(Action::SidebarHidden(true));
                                            }
                                            state.write().mutate(Action::ChatWith(&chat.id, false));
                                            if cx.props.route_info.active.to != UPLINK_ROUTES.chat {
                                                router.replace_route(UPLINK_ROUTES.chat, None, None);
                                            }
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
                Nav {
                    routes: cx.props.route_info.routes.clone(),
                    active: cx.props.route_info.active.clone(),
                    tooltip_direction: ArrowPosition::Left,
                    onnavigate: move |r| {
                        if state.read().configuration.audiovideo.interface_sounds {
                            common::sounds::Play(common::sounds::Sounds::Interaction);
                        }
                        if state.read().ui.is_minimal_view() {
                            state.write().mutate(Action::SidebarHidden(true));
                        }
                        router.replace_route(r, None, None);
                    }
                },
            )),
        }
    ))
}
