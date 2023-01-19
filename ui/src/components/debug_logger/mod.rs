use std::time::Duration;

use chrono::Local;
use dioxus::prelude::*;

use dioxus_desktop::use_window;
use kit::elements::label::Label;
use tokio::time::sleep;

use crate::{components::settings::sub_pages::developer::WindowDropHandler, logger::Logger};

const STYLE: &str = include_str!("./style.scss");

#[inline_props]
#[allow(non_snake_case)]
pub fn DebugLogger(cx: Scope, _drop_handler: WindowDropHandler) -> Element {
    Logger::get_logger().activate_logger();
    let window = use_window(cx);

    let logs_to_show = use_state(cx, || Logger::get_logger().load_logs_from_file());

    let logs_on_screen_len = use_ref(cx, || 0);

    let now = Local::now();
    let formatted_datetime = now.format("%a %b %d %H:%M:%S").to_string();
    let debug_logger_started_time = use_ref(cx, || formatted_datetime.clone());

    let script = include_str!("./script.js");

    use_future(cx, (), |_| {
        to_owned![logs_to_show, window, script, logs_on_screen_len];
        async move {
            loop {
                sleep(Duration::from_millis(100)).await;
                let new_logs = Logger::get_log_entries();
                if new_logs.len() > *logs_on_screen_len.read() {
                    *logs_on_screen_len.write_silent() = new_logs.len();
                    logs_to_show.set(new_logs);
                    window.eval(&script);
                }
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
                let log_level = log.level.to_str();
                let log_message = log.message.clone();
                let log_datetime = format!("[{}]",log.datetime);
                let log_color = log.level.color();
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
