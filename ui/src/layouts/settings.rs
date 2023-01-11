use dioxus::prelude::*;
use dioxus_router::use_router;

use crate::{
    components::{
        chat::RouteInfo,
        settings::{
            sidebar::{Page, Sidebar},
            sub_pages::{
                audio::AudioSettings, developer::DeveloperSettings, extensions::ExtensionSettings,
                files::FilesSettings, general::GeneralSettings, privacy::PrivacySettings,
                profile::ProfileSettings,
            },
        },
    },
    state::{Action, State},
};

use kit::{components::nav::Nav, layout::topbar::Topbar};

#[derive(PartialEq, Props)]
pub struct Props {
    route_info: RouteInfo,
}

#[allow(non_snake_case)]
pub fn SettingsLayout(cx: Scope<Props>) -> Element {
    let state = use_shared_state::<State>(cx)?;
    let to = use_state(cx, || Page::Profile);

    cx.render(rsx!(
        div {
            id: "settings-layout",
            aria_label: "settings-layout",
            Sidebar {
                route_info: cx.props.route_info.clone(),
                onpress: move |p| {
                    // TODO: If on mobile, we should hide the sidebar here.
                    to.set(p);
                },
            },
            div {
                class: "full-width flex",
                Topbar {
                    with_back_button: true,
                    with_currently_back: state.read().ui.sidebar_hidden,
                    onback: move |_| {
                        let current = state.read().ui.sidebar_hidden;
                        state.write().mutate(Action::SidebarHidden(!current));
                    },
                },
                div {
                    id: "content",
                    class: "full-width",
                    match to.get() {
                        Page::Profile       => cx.render(rsx! (
                            ProfileSettings {}
                        )),
                        Page::General       => cx.render(rsx! (
                            GeneralSettings {}
                        )),
                        Page::Audio         => cx.render(rsx! (
                            AudioSettings {}
                        )),
                        Page::Privacy       => cx.render(rsx! (
                            PrivacySettings {}
                        )),
                        Page::Files         => cx.render(rsx! (
                            FilesSettings {}
                        )),
                        Page::Extensions    => cx.render(rsx! (
                            ExtensionSettings {}
                        )),
                        Page::Developer     => cx.render(rsx! (
                            DeveloperSettings {}
                        ))
                    }
                },
                state.read().ui.sidebar_hidden.then(|| rsx!(
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
