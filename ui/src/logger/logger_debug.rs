use std::time::Duration;

use chrono::Local;
use dioxus::prelude::*;

use kit::elements::label::Label;
use tokio::time::sleep;

use super::logger::Logger;

#[allow(non_snake_case)]
pub fn LoggerDebug(cx: Scope) -> Element {
    let logger = Logger::load();
    let logs = logger.show_log();

    let logs_to_show = use_state(cx, || logs.clone());

    use_future(cx, (), |_| {
        to_owned![logs_to_show];
        async move {
            loop {
                sleep(Duration::from_millis(100)).await;
                let new_logs = logger.show_log();
                if new_logs.len() != logs_to_show.len() {
                    logs_to_show.set(new_logs);
                }
            }
        }
    });

    cx.render(rsx!(
        div {
            class: "logger-body",
            background_color: "black",
            height: "10000px",
            width: "10000px",
            margin: "-50px",
            // overscroll_behavior_y: "none",
            // overscroll_behavior_x: "none",
            overflow: "hidden",
            Label { text: "Starting Logger Debug".to_owned() },
            logs_to_show.iter().map(|log| {
                let log_string = format!("{:?}", log);
                let log_color = log.level.color();
                let datetime_now = Local::now();
                rsx!(p {
                    class: "log-text",
                    color: "{log_color}",
                    "{log_string} -> {datetime_now}"
                })
            })
    }
    ))
}
