use dioxus::prelude::*;
use dioxus_router::use_router;

use crate::{
    components::{
        chat::RouteInfo,
        settings::{
            sidebar::{Page, Sidebar},
            sub_pages::{
                audio::AudioSettings, developer::DeveloperSettings, extensions::ExtensionSettings,
                files::FilesSettings, general::GeneralSettings,
                notifications::NotificationSettings, privacy::PrivacySettings,
                profile::ProfileSettings,
            },
        },
    },
    state::{ui, Action, State},
};

use kit::{components::nav::Nav, layout::topbar::Topbar};

#[derive(PartialEq, Props)]
pub struct Props {
    route_info: RouteInfo,
}

#[allow(non_snake_case)]
pub fn SettingsLayout(cx: Scope<Props>) -> Element {
    let state = use_shared_state::<State>(cx)?;
    let to = use_state(cx, || Page::General);

    state.write_silent().ui.current_layout = ui::Layout::Settings;

    let first_render = use_state(cx, || true);
    if *first_render.get() {
        if state.read().ui.is_minimal_view() {
            state.write().mutate(Action::SidebarHidden(false));
        }
        first_render.set(false);
    }

    let settings_page = match to.get() {
        Page::General => rsx!(GeneralSettings {}),
        Page::Profile => rsx!(ProfileSettings {}),
        Page::Audio => rsx!(AudioSettings {}),
        Page::Privacy => rsx!(PrivacySettings {}),
        Page::Files => rsx!(FilesSettings {}),
        Page::Extensions => rsx!(ExtensionSettings {}),
        Page::Developer => rsx!(DeveloperSettings {}),
        Page::Notifications => rsx!(NotificationSettings {}),
    };

    cx.render(rsx!(
        div {
            id: "settings-layout",
            aria_label: "settings-layout",
            Sidebar {
                route_info: cx.props.route_info.clone(),
                onpress: move |p| {
                    // If on mobile, we should hide the sidebar here.
                    if state.read().ui.is_minimal_view() {
                        state.write().mutate(Action::SidebarHidden(true));
                    }
                    to.set(p);
                },
            },
            div {
                class: "full-width flex",
                (state.read().ui.is_minimal_view() || state.read().ui.sidebar_hidden).then(|| rsx!(
                    Topbar {
                        with_back_button: true,
                        with_currently_back: state.read().ui.sidebar_hidden,
                        onback: move |_| {
                            let current = state.read().ui.sidebar_hidden;
                            state.write().mutate(Action::SidebarHidden(!current));
                        },
                    },
                )),
                div {
                    id: "content",
                    class: "full-width",
                    settings_page
                },
                (state.read().ui.sidebar_hidden && state.read().ui.metadata.minimal_view).then(|| rsx!(
                    Nav {
                        routes: cx.props.route_info.routes.clone(),
                        active: cx.props.route_info.active.clone(),
                        onnavigate: move |r| {
                            use_router(cx).replace_route(r, None, None);
                        }
                    }
                ))
            },
        }
    ))
}
