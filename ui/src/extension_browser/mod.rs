// This is a dioxus component which will allow browsing of the extension "marketplace".

use common::state::action::ConfigAction;
use common::state::Action;
use common::{icons::outline::Shape as Icon, language::get_local_text, state::State, STATIC_ARGS};

use crate::components::settings::{ExtensionSetting, SettingSection};
use common::sounds;
use dioxus::prelude::*;
use kit::elements::input::{Input, Options};
use kit::{
    components::nav::{Nav, Route},
    elements::{button::Button, switch::Switch},
};

#[allow(non_snake_case)]
pub fn Settings(cx: Scope) -> Element {
    let state = use_shared_state::<State>(cx)?;

    cx.render(rsx! (
            div {
                class: "extensions-settings",
                SettingSection {
                    section_label: get_local_text("settings-extensions.open-extensions-folder"),
                    section_description: get_local_text("settings-extensions.open-folder-description"),
                    Button {
                        icon: Icon::FolderOpen,
                        text: get_local_text("settings-extensions.open-extensions-folder"),
                        aria_label: "open-extensions-folder-button".into(),
                        onpress: move |_| {
                            let _ = opener::open(&STATIC_ARGS.extensions_path);
                        }
                    },
                },
                SettingSection {
                    section_label: get_local_text("settings-extensions.auto-enable"),
                    section_description: get_local_text("settings-extensions.auto-enable-description"),
                    Switch {
                        active: state.read().configuration.extensions.enable_automatically,
                        onflipped: move |value| {
                            if state.read().configuration.audiovideo.interface_sounds {
                                sounds::Play(sounds::Sounds::Flip);
                            }
                            state.write().mutate(Action::Config(ConfigAction::SetAutoEnableExtensions(value)));
                        },
                    }
                },
            }
        ))
}

#[allow(non_snake_case)]
pub fn Explore(cx: Scope) -> Element {
    cx.render(rsx! (
        div {
            class: "extensions-explore",
            span {
                class: "banner",
                get_local_text("settings-extensions.banner")
            },
            Input {
                placeholder: "Extension name or description.".into(),
                // TODO: Pending implementation
                disabled: true,
                aria_label: "extensions-search-input".into(),
                icon: Icon::MagnifyingGlass,
                options: Options {
                    with_label: String::from("Search Extensions").into(),
                    with_clear_btn: true,
                    ..Default::default()
                }
            }
        }
    ))
}

#[allow(non_snake_case)]
pub fn Installed(cx: Scope) -> Element {
    let state = use_shared_state::<State>(cx)?;
    let metas: Vec<_> = state
        .read()
        .ui
        .extensions
        .values()
        .map(|ext| (ext.enabled(), ext.details().meta.clone()))
        .collect();

    cx.render(rsx!(
            metas.iter().cloned().map(|(enabled, meta)| {
                rsx!(
                    ExtensionSetting {
                        title: meta.pretty_name.to_owned(),
                        author: meta.author.to_owned(),
                        description: meta.description.to_owned(),
                        Switch {
                            active: enabled,
                            onflipped: move |value| {
                                if state.read().configuration.audiovideo.interface_sounds {
                                    sounds::Play(sounds::Sounds::Flip);
                                }

                                state.write().mutate(Action::SetExtensionEnabled(meta.name.to_owned(), value));
                            }
                        }
                    }
                )
            })
        ))
}

#[allow(non_snake_case)]
pub fn ExtensionsBrowser(cx: Scope) -> Element {
    let routes = vec![
        Route {
            name: "Installed".into(),
            icon: Icon::CheckCircle,
            to: "installed",
            ..Default::default()
        },
        Route {
            name: "Explore".into(),
            icon: Icon::Sparkles,
            to: "explore",
            ..Default::default()
        },
        Route {
            name: "Settings".into(),
            icon: Icon::Cog6Tooth,
            to: "settings",
            ..Default::default()
        },
    ];

    let active_route = use_state(cx, || "installed");

    cx.render(rsx!(
        div {
            id: "extensions-browser",
            Nav {
                active: routes[0].clone(),
                bubble: true,
                routes: routes,
                onnavigate: move |r| {
                    active_route.set(r);
                }
            },
            (*active_route.get() == "installed").then(|| rsx!(
                Installed {}
            )),
            (*active_route.get() == "explore").then(|| rsx!(
                Explore {}
            )),
            (*active_route.get() == "settings").then(|| rsx!(
                Settings {}
            ))
        }
    ))
}
