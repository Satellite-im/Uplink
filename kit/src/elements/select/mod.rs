use std::collections::HashSet;

use dioxus::prelude::*;

#[derive(Props)]
pub struct Props<'a> {
    #[props(optional)]
    _loading: Option<bool>,
    options: Vec<String>,
    #[props(optional)]
    onselect: Option<EventHandler<'a, String>>,
    initial_value: String,
}

/// Tells the parent the button was interacted with.
pub fn emit(cx: &Scope<Props>, s: String) {
    match &cx.props.onselect {
        Some(f) => f.call(s),
        None => {}
    }
}

fn remove_duplicates(values: Vec<String>) -> Vec<String> {
    let unique_values: HashSet<_> = values.iter().cloned().collect();
    let mut unique_values_vec: Vec<String> = Vec::new();
    unique_values_vec.extend(unique_values);
    unique_values_vec
}

#[allow(non_snake_case)]
pub fn Select<'a>(cx: Scope<'a, Props<'a>>) -> Element<'a> {
    let initial_value = cx.props.initial_value.clone();
    let mut options = remove_duplicates(cx.props.options.clone());
    options.retain(|value| value != &initial_value);
    options.insert(0, initial_value.clone());
    let iter = IntoIterator::into_iter(options.clone());

    // TODO: We should iterate through the options and figure out the maximum length of an option
    // use this to calculate the min-width of the selectbox. Our max width should always be 100%.
    cx.render(rsx!(
        div {
            class: "select",
            aria_label: "Selector",
            select {
                value: "{initial_value}",
                onchange: move |e| emit(&cx, e.value.clone()),
                iter.map(|val|
                    rsx!(option {key: "{val}", label: "{val}", value: "{val}", aria_label: "Selector Option"})
                )
            }
        }
    ))
}
