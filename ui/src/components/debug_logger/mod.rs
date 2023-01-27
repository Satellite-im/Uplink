use std::str::FromStr;

use chrono::Local;
use dioxus::prelude::*;

use dioxus_desktop::use_window;
use kit::elements::label::Label;
use warp::logging::tracing::log::Level;

use crate::{components::settings::sub_pages::developer::WindowDropHandler, logger};

const STYLE: &str = include_str!("./style.scss");

#[inline_props]
#[allow(non_snake_case)]
pub fn DebugLogger(cx: Scope, _drop_handler: WindowDropHandler) -> Element {
    let window = use_window(cx);

    let logs_to_show = use_state(cx, logger::load_debug_log);

    let now = Local::now();
    let formatted_datetime = now.format("%a %b %d %H:%M:%S").to_string();
    let debug_logger_started_time = use_ref(cx, || formatted_datetime.clone());

    let script = include_str!("./script.js");

    use_future(cx, (), |_| {
        to_owned![logs_to_show, window, script];
        async move {
            let mut log_ch = logger::subscribe();
            while let Some(log) = log_ch.recv().await {
                logs_to_show.with_mut(|x| x.push(log.to_string()));
                window.eval(&script);
            }
        }
    });

    cx.render(rsx!(
        style { STYLE }
        div {
            id: "debug_logger",
            class: "debug-logger",
            div {
                class: "initial-label",
                Label {
                    text: format!("{}: {}", "Logger Debug opened on".to_owned(), *debug_logger_started_time.read())},
            },
            logs_to_show.iter().map(|log| {
               
                let mut fields = log.split('|');
                let log_datetime = fields.next().unwrap_or_default();
                let log_level = fields.next().unwrap_or_default();
                let log_message = fields.next().unwrap_or_default();
                let log_color = logger::get_color_string(Level::from_str(log_level).unwrap_or(Level::Debug));
                rsx!(
                    div {
                        display: "flex",
                        p {
                            class: "log-text",
                            color: "rgb(199, 136, 19)",
                            "{log_datetime}"
                            },
                        p {
                            class: "log-text",
                            color: "{log_color}",
                            "{log_level}:"
                            }
                        p {
                            id: "log_text",
                            class: "log-text",
                            color: "white",
                            "{log_message}"
                        }
                    }
                )
            })
        }
    ))
}
