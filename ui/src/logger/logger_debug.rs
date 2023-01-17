use std::time::Duration;

use chrono::Local;
use dioxus::prelude::*;

use dioxus_desktop::use_window;
use kit::elements::label::Label;
use tokio::time::sleep;

use super::logger::{Logger, LOGGER};

const STYLE: &str = include_str!("./style.scss");

#[allow(non_snake_case)]
pub fn LoggerDebug(cx: Scope) -> Element {
    Logger::activate_logger();
    let logger = LOGGER.read();
    let logs = logger.show_log();

    let logs_to_show = use_state(cx, || logs.clone());

    // let script = r#"
    //     var objDiv = document.getElementById("debug_logger");
    //     objDiv.scrollTop = objDiv.scrollHeight;
    // "#;

    let logs_on_screen_len = use_ref(cx, || 0);

    let window = use_window(cx);
    let script = include_str!("./script.js");

    use_future(cx, (), |_| {
        to_owned![logs_to_show, window, script, logs_on_screen_len];
        async move {
            loop {
                sleep(Duration::from_millis(100)).await;
                let new_logs = logger.show_log();
                if new_logs.len() > *logs_on_screen_len.read() {
                    *logs_on_screen_len.write_silent() = new_logs.len();
                    logs_to_show.set(new_logs);
                    window.eval(&script);
                }
            }
        }
    });

    let now = Local::now();
    let formatted_datetime = now.format("%a %b %d %H:%M:%S").to_string();

    cx.render(rsx!(
        style { STYLE }
        div {
            id: "debug_logger",
            class: "debug-logger",
            div {
                class: "initial-label",
                Label {
                    text: format!("{}: {}", "Starting Logger Debug".to_owned(), formatted_datetime)},
            },
            logs_to_show.iter().map(|log| {
                let log_string = format!("{} -> {:?}: {}", log.datetime, log.level, log.message);
                let log_color = log.level.color();
                rsx!(p {
                    id: "log_text",
                    class: "log-text",
                    color: "{log_color}",
                    "{log_string}"
                })
            })
        }
    ))
}
