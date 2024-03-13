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
            keybinds::KeybindSettings,
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
pub fn SettingsLayout() -> Element {
    let state = use_context::<Signal<State>>();
    let to = use_context::<Signal<Page>>();
    let show_slimbar = state.read().show_slimbar() & !state.read().ui.is_minimal_view();

    state.write_silent().ui.current_layout = ui::Layout::Settings;

    let first_render = use_signal(|| true);
    if *first_render.get() {
        if state.read().ui.is_minimal_view() {
            state.write().mutate(Action::SidebarHidden(false));
        }
        first_render.set(false);
    }

    let settings = match to.read().get() {
        Page::About => rsx!(AboutPage {}),
        Page::General => rsx!(GeneralSettings {}),
        Page::Messages => rsx!(Messages {}),
        Page::Accessibility => rsx!(AccessibilitySettings {}),
        Page::Profile => rsx!(ProfileSettings {}),
        Page::Audio => rsx!(AudioSettings {}),
        // Page::Privacy => rsx!(PrivacySettings {}),
        // Page::Files => rsx!(FilesSettings {}),
        Page::Extensions => rsx!(ExtensionSettings {}),
        Page::Keybinds => rsx!(KeybindSettings {}),
        Page::Developer => rsx!(DeveloperSettings {}),
        Page::Notifications => rsx!(NotificationSettings {}),
        Page::Licenses => rsx!(Licenses {}),
    };

    rsx!(
        div {
            id: "settings-layout",
            aria_label: "settings-layout",
            if show_slimbar {
                rsx!(
                    SlimbarLayout { active: crate::UplinkRoute::SettingsLayout{} },
                )
            },
            Sidebar {
                onpress: move |p| {
                    to.write().set(p);
                    // If on mobile, we should hide the sidebar here.
                    if state.read().ui.is_minimal_view() {
                        state.write().mutate(Action::SidebarHidden(true));
                    }
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
                    settings,
                },
                 (state.read().ui.sidebar_hidden && state.read().ui.metadata.minimal_view).then(|| rsx!(
                    crate::AppNav {
                        active: crate::UplinkRoute::SettingsLayout{},
                    }
                 ))
            },
        }
    )
}
