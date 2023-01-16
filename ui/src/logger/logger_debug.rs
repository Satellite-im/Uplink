use std::time::Duration;

use chrono::Local;
use dioxus::prelude::*;

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

    use_future(cx, (), |_| {
        to_owned![logs_to_show];
        async move {
            loop {
                sleep(Duration::from_millis(100)).await;
                let new_logs = logger.show_log();
                if new_logs.len() > logs_to_show.len() {
                    logs_to_show.set(new_logs);
                }
            }
        }
    });

    let now = Local::now();
    let formatted_datetime = now.format("%a %b %d %H:%M:%S").to_string();

    cx.render(rsx!(
        style { STYLE }
        div {
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
