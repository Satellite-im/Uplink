use std::{
    sync::Mutex,
    time::{Duration, Instant},
};

use common::state::{Action, State};
use dioxus_hooks::UseSharedState;
use once_cell::sync::Lazy;

use crate::utils::get_font_sizes::{FONT_SIZE_BIGGEST, FONT_SIZE_SMALLEST};

// TODO: This fires once on key-down as well as key-up we should fix this in the future.
static LAST_CALLED: Lazy<Mutex<Instant>> =
    Lazy::new(|| Mutex::new(Instant::now() - Duration::from_secs(1)));

fn debounced_callback<F: FnOnce()>(callback: F, debounce_duration: Duration) {
    let mut last_called = LAST_CALLED.lock().unwrap();
    let now = Instant::now();

    if now.duration_since(*last_called) > debounce_duration {
        callback();
        *last_called = now;
    }
}

pub fn increase_size(state: UseSharedState<State>) {
    debounced_callback(
        || {
            let value = state.read().settings.font_scale();
            if value < FONT_SIZE_BIGGEST {
                state.write().mutate(Action::SetFontScale(value + 0.25));
            }
        },
        Duration::from_millis(500),
    );
}

pub fn decrease_size(state: UseSharedState<State>) {
    debounced_callback(
        || {
            let value = state.read().settings.font_scale();
            if value > FONT_SIZE_SMALLEST {
                state.write().mutate(Action::SetFontScale(value - 0.25));
            }
        },
        Duration::from_millis(500),
    );
}
