use common::state::{Action, State};
use dioxus::prelude::*;

pub fn toggle_mute(state: UseSharedState<State>) {
    state.write().mutate(Action::ToggleMute);
}

pub fn toggle_deafen(state: UseSharedState<State>) {
    state.write().mutate(Action::ToggleSilence);
}
