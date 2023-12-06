use dioxus::prelude::*;

use common::{
    icons::outline::Shape as Icon,
    state::{utils::get_available_themes, Action, State},
};
use kit::elements::{
    button::Button,
    label::Label,
    switch::Switch,
    tooltip::{ArrowPosition, Tooltip},
    Appearance,
};

use common::icons::Icon as IconElement;

use dioxus_desktop::use_window;
use log::Level;

use crate::logger;

const STYLE: &str = include_str!("./style.scss");
const SCRIPT: &str = include_str!("./script.js");

#[derive(PartialEq, Eq, Copy, Clone)]
pub enum Tab {
    Logs,
    State,
}

#[component]
#[allow(non_snake_case)]
pub fn DebugLogger(cx: Scope) -> Element {
    let window = use_window(cx);

    let logs_to_show = use_state(cx, logger::load_debug_log);

    use_future(cx, (), |_| {
        to_owned![logs_to_show];
        async move {
            let mut log_ch = logger::subscribe();
            while let Some(log) = log_ch.recv().await {
                logs_to_show.with_mut(|x| x.push(log));
            }
        }
    });

    let eval = use_eval(cx);

    let active_tab: &UseState<Tab> = use_state(cx, || Tab::Logs);
    let filter_level: &UseState<Level> = use_state(cx, || Level::Error); // If debug is set, we will not filter at all

    let state = use_shared_state::<State>(cx)?;

    let state_json = state.read().get_json();

    cx.render(rsx!(
        style { STYLE }
        div {
            onmounted: move |_| { _ = eval(SCRIPT) },
            id: "debug_logger",
            aria_label: "debug-logger",
            class: "debug-logger resize-vert-top",
            div {
                class: "header",
                aria_label: "debug-logger-header",
                div {
                    class: "logger-nav",
                    aria_label: "debug-logger-nav",
                    Button {
                        text: "Logs".into(),
                        icon: Icon::CommandLine,
                        appearance: if *active_tab.get() == Tab::Logs { Appearance::Primary } else { Appearance::Secondary },
                        onpress: |_| {
                            active_tab.set(Tab::Logs);
                        }
                    },
                    (active_tab.get() == &Tab::Logs).then(|| cx.render(rsx!{
                        div {
                            class: "section",
                            Label {
                                text: "Filter:".into(),
                            },
                            Button {
                                icon: Icon::BugAnt,
                                appearance: Appearance::Secondary,
                                onpress: |_| {
                                    filter_level.set(Level::Debug);
                                },
                                tooltip: cx.render(rsx!(
                                    Tooltip {
                                        arrow_position: ArrowPosition::Top,
                                        text: "Debug".into()
                                    }
                                )),
                            },
                            Button {
                                icon: Icon::InformationCircle,
                                appearance: if *filter_level.get() == Level::Info { Appearance::Info } else { Appearance::Secondary },
                                onpress: |_| {
                                    filter_level.set(Level::Info);
                                },
                                tooltip: cx.render(rsx!(
                                    Tooltip {
                                        arrow_position: ArrowPosition::Top,
                                        text: "Info".into()
                                    }
                                )),
                            },
                            Button {
                                icon: Icon::ExclamationTriangle,
                                appearance: if *filter_level.get() == Level::Error { Appearance::Danger } else { Appearance::Secondary },
                                onpress: |_| {
                                    filter_level.set(Level::Error);
                                },
                                tooltip: cx.render(rsx!(
                                    Tooltip {
                                        arrow_position: ArrowPosition::Top,
                                        text: "Error".into()
                                    }
                                )),
                            },
                            Button {
                                icon: Icon::Eye,
                                appearance: Appearance::Secondary,
                                onpress: |_| {
                                    filter_level.set(Level::Trace);
                                },
                                tooltip: cx.render(rsx!(
                                    Tooltip {
                                        arrow_position: ArrowPosition::Top,
                                        text: "Trace".into()
                                    }
                                )),
                            },
                        }
                    })),
                    Button {
                        text: "State".into(),
                        icon: Icon::Square3Stack3d,
                        appearance: if *active_tab.get() == Tab::State { Appearance::Primary } else { Appearance::Secondary },
                        onpress: |_| {
                            active_tab.set(Tab::State);
                        }
                    },
                    Button {
                        text: "Web Inspector".into(),
                        icon: Icon::ArrowTopRightOnSquare,
                        appearance: Appearance::Secondary,
                        onpress: |_| {
                            window.webview.open_devtools();
                        }
                    },
                },
                div {
                    class: "logger-nav-right",
                    aria_label: "debug-logger-nav-right",
                    IconElement {
                        icon: if state.read().ui.theme.clone().unwrap_or_default().name == "Light" {
                            Icon::Sun
                        } else {
                            Icon::Moon
                        }
                    },
                    Switch {
                        active: state.read().ui.theme.clone().unwrap_or_default().name == "Light",
                        onflipped: move |_| {
                            let current_theme = state.read().ui.theme.clone().unwrap_or_default();

                            if current_theme.name != "Light" {
                                let light_theme = get_available_themes().iter().find(|t| t.name == "Light").unwrap().clone();
                                state.write().mutate(Action::SetTheme(Some(light_theme)));
                            } else {
                                state.write().mutate(Action::SetTheme(None));
                            }
                        }
                    }
                },
            },
            match active_tab.get() {
                Tab::Logs => rsx!(div {
                    aria_label: "debug-logger-body",
                    class: "body",
                    div {
                        class: "body-scroll",
                        logs_to_show.iter().filter(
                            |&x| x.level == *filter_level.get() || *filter_level.get() == Level::Debug
                        ).map(|log| {
                            let log_datetime = log.datetime;
                            let log_level = log.level;
                            let log_message = log.message.clone();
                            let log_level_string = log.level;
                            rsx!(
                                p {
                                    class: "item",
                                    aria_label: "debug-logger-item",
                                    span {
                                        aria_label: "debug-logger-item-timestamp",
                                        class: "log-text muted",
                                        "{log_datetime}"
                                    },
                                    span {
                                        aria_label: "debug-logger-item-level",
                                        class: "log-text bold {log_level_string}",
                                        "{log_level}"
                                    },
                                    span {
                                        class: "log-text muted",
                                        "»"
                                    }
                                    span {
                                        aria_label: "debug-logger-item-text",
                                        id: "log_text",
                                        class: "log-text",
                                        " {log_message}"
                                    }
                                }
                            )
                        })
                    }
                }),
                Tab::State => rsx!(div {
                    aria_label: "debug-logger-body",
                    class: "body",
                    pre {
                        class: "language-js",

                        code {
                            "{state_json}"
                        }
                    }
                    script {
                        r#"
                        (() => {{
                            Prism.highlightAll();
                        }})();
                        "#
                    }
                })
            }
        },
    ))
}
