use std::time::Duration;

use dioxus::prelude::*;

use tokio::time::sleep;

use crate::logger::Logger;

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

    cx.render(rsx!(div {
        background: "black",
        width: "100%",
        height: "100%",
        logs_to_show.iter().map(|log| {
            let log_string = format!("{:?}", log);
            let log_color = log.level.color();
            rsx!(p {
                font_size: "16px",
                margin_left: "16px",
                color: "{log_color}",
                "{log_string}"
            })
        })
    }))
}
