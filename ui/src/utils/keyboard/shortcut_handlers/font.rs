use common::state::{Action, State};
use dioxus_hooks::UseSharedState;

use crate::utils::get_font_sizes::{FONT_SIZE_BIGGEST, FONT_SIZE_SMALLEST};

pub fn increase_size(state: UseSharedState<State>) {
    let value = state.read().settings.font_scale();
    if value < FONT_SIZE_BIGGEST {
        state.write().mutate(Action::SetFontScale(value + 0.25));
    }
}

pub fn decrease_size(state: UseSharedState<State>) {
    let value = state.read().settings.font_scale();
    if value > FONT_SIZE_SMALLEST {
        state.write().mutate(Action::SetFontScale(value - 0.25));
    }
}
