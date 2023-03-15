use dioxus::prelude::*;

use dioxus_desktop::use_eval;
use kit::elements::label::Label;

use crate::logger;

const STYLE: &str = include_str!("./style.scss");
const SCRIPT: &str = include_str!("./script.js");

#[inline_props]
#[allow(non_snake_case)]
pub fn DebugLogger(cx: Scope) -> Element {
    let logs_to_show = use_state(cx, logger::load_debug_log);

    use_future(cx, (), |_| {
        to_owned![logs_to_show];
        async move {
            let mut log_ch = logger::subscribe();
            while let Some(log) = log_ch.recv().await {
                logs_to_show.with_mut(|x| x.push(log.to_string()));
            }
        }
    });

    // Run the script after the component is mounted
    let eval = use_eval(cx);
    use_effect(cx, (), |_| {
        to_owned![eval];
        async move {
            eval(SCRIPT.to_string());
        }
    });

    cx.render(rsx!(
        style { STYLE }
        div {
            id: "debug_logger",
            aria_label: "debug-logger",
            class: "debug-logger resize-vert-top",
            div {
                class: "header",
                aria_label: "debug-logger-header",
                Label {
                    text: "Logger".into()
                }
            },
            div {
                aria_label: "debug-logger-body",
                class: "body",
                div {
                    logs_to_show.iter().map(|log| {
                        let mut fields = log.split('|');
                        let log_datetime = fields.next().unwrap_or_default();
                        let log_level = fields.next().unwrap_or_default();
                        let log_message = fields.next().unwrap_or_default();
                        let log_level_string = log_level.trim().to_lowercase();
                        rsx!(
                            p {
                                class: "item",
                                aria_label: "debug-logger-item",
                                span {
                                    aria_label: "debug-logger-item-timestamp",
                                    class: "log-text muted",
                                    "〇 {log_datetime}"
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
            }
        },
    ))
}
