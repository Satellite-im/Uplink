use std::str::FromStr;

use chrono::Local;
use dioxus::prelude::*;

use kit::elements::label::Label;
use warp::logging::tracing::log::Level;

use crate::logger;

const STYLE: &str = include_str!("./style.scss");
const SCRIPT: &str = include_str!("./script.js");

#[inline_props]
#[allow(non_snake_case)]
pub fn DebugLogger(cx: Scope) -> Element {
    let logs_to_show = use_state(cx, logger::load_debug_log);

    let now = Local::now();
    let formatted_datetime = now.format("%a %b %d %H:%M:%S").to_string();
    let debug_logger_started_time = use_ref(cx, || formatted_datetime.clone());

    use_future(cx, (), |_| {
        to_owned![logs_to_show];
        async move {
            let mut log_ch = logger::subscribe();
            while let Some(log) = log_ch.recv().await {
                logs_to_show.with_mut(|x| x.push(log.to_string()));
            }
        }
    });

    cx.render(rsx!(
        style { STYLE }
        div {
            id: "debug_logger",
            class: "debug-logger resize-vert-top",
            div {
                div {
                    class: "initial-label",
                    Label {
                        text: format!("{} {}", "Logger Debug opened on".to_owned(), *debug_logger_started_time.read())
                    },
                },
                logs_to_show.iter().map(|log| {
                    let mut fields = log.split('|');
                    let log_datetime = fields.next().unwrap_or_default();
                    let log_level = fields.next().unwrap_or_default();
                    let log_message = fields.next().unwrap_or_default();
                    let log_color = logger::get_color_string(Level::from_str(log_level).unwrap_or(Level::Debug));
                    
                    rsx!(
                        p {
                            class: "item",
                            span {
                                class: "log-text muted",
                                "〇 {log_datetime}"
                            },
                            span {
                                class: "log-text bold",
                                color: "{log_color}",
                                "{log_level}"
                            },
                            span {
                                class: "log-text muted",
                                "»"
                            }
                            span {
                                id: "log_text",
                                class: "log-text",
                                " {log_message}"
                            }
                        }
                    )
                })
            }
        },
        script { SCRIPT }
    ))
}
