use crate::{
    components::chat::{compose::Compose, sidebar::Sidebar as ChatSidebar, welcome::Welcome},
    layouts::slimbar::SlimbarLayout,
};

use common::state::{ui, Action, State};
use dioxus::prelude::*;

#[allow(non_snake_case)]
pub fn ChatLayout(cx: Scope) -> Element {
    let state = use_shared_state::<State>(cx)?;
    let first_render = use_state(cx, || true);

    state.write_silent().ui.current_layout = ui::Layout::Welcome;

    let is_minimal_view = state.read().ui.is_minimal_view();
    let sidebar_hidden = state.read().ui.sidebar_hidden;
    let show_welcome = state.read().chats().active.is_none();

    if *first_render.get() && is_minimal_view {
        state.write().mutate(Action::SidebarHidden(true));
        first_render.set(false);
    }

    cx.render(rsx!(
        div {
            id: "chat-layout",
            aria_label: "chat-layout",
            SlimbarLayout { active: crate::UplinkRoute::ChatLayout{} },
            // todo: consider showing a welcome screen if the sidebar is to be shown but there are no conversations in the sidebar. this case arises when
            // creating a new account on a mobile device.
            ChatSidebar {
                active_route: crate::UplinkRoute::ChatLayout {},
            },
            show_welcome.then(|| rsx!(Welcome {})),
            (!show_welcome && (sidebar_hidden  || !state.read().ui.is_minimal_view())).then(|| rsx!(Compose {}))
        }
    ))
}
