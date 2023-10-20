use dioxus::prelude::*;

use crate::{
    components::settings::{
        sidebar::{Page, Sidebar},
        sub_pages::{
            about::AboutPage,
            accessibility::AccessibilitySettings,
            audio::AudioSettings,
            developer::DeveloperSettings,
            extensions::ExtensionSettings,
            general::GeneralSettings,
            licenses::Licenses,
            messages::Messages,
            notifications::NotificationSettings,
            // files::FilesSettings,
            // privacy::PrivacySettings,
            profile::ProfileSettings,
        },
    },
    layouts::slimbar::SlimbarLayout,
};

use common::state::{ui, Action, State};

use kit::layout::topbar::Topbar;

#[allow(non_snake_case)]
pub fn SettingsLayout(cx: Scope) -> Element {
    let state = use_shared_state::<State>(cx)?;
    let to = use_state(cx, || Page::Profile);

    state.write_silent().ui.current_layout = ui::Layout::Settings;

    let first_render = use_state(cx, || true);
    if *first_render.get() {
        if state.read().ui.is_minimal_view() {
            state.write().mutate(Action::SidebarHidden(false));
        }
        first_render.set(false);
    }

    let settings_page = match to.get() {
        Page::About => rsx!(AboutPage {}),
        Page::General => rsx!(GeneralSettings {}),
        Page::Messages => rsx!(Messages {}),
        Page::Accessibility => rsx!(AccessibilitySettings {}),
        Page::Profile => rsx!(ProfileSettings {}),
        Page::Audio => rsx!(AudioSettings {}),
        // Page::Privacy => rsx!(PrivacySettings {}),
        // Page::Files => rsx!(FilesSettings {}),
        Page::Extensions => rsx!(ExtensionSettings {}),
        Page::Developer => rsx!(DeveloperSettings {}),
        Page::Notifications => rsx!(NotificationSettings {}),
        Page::Licenses => rsx!(Licenses {}),
    };

    cx.render(rsx!(
        div {
            id: "settings-layout",
            aria_label: "settings-layout",
            SlimbarLayout { active: crate::UplinkRoute::SettingsLayout{} },
            Sidebar {
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
                (state.read().ui.is_minimal_view() && state.read().ui.sidebar_hidden).then(|| rsx!(
                    Topbar {
                        with_back_button: true,
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
                    crate::AppNav {
                        active: crate::UplinkRoute::SettingsLayout{},
                    }
                 ))
            },
        }
    ))
}
