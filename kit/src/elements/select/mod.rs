use std::collections::HashSet;

use dioxus::prelude::*;
use dioxus_elements::GlobalAttributes;

use crate::components::invisible_closer::InvisibleCloser;

#[derive(Props)]
pub struct Props<'a> {
    #[props(optional)]
    _loading: Option<bool>,
    options: Vec<String>,
    #[props(optional)]
    onselect: Option<EventHandler<String>>,
    initial_value: String,
}

/// Tells the parent the button was interacted with.
pub fn emit(cx: &Scope<Props>, s: String) {
    match &props.onselect {
        Some(f) => f.call(s),
        None => {}
    }
}

fn remove_duplicates(values: Vec<String>) -> Vec<String> {
    let mut set = HashSet::new();
    values
        .iter()
        .filter(|v| set.insert(v.to_string()))
        .cloned()
        .collect()
}

fn remove_duplicates_fancy(values: Vec<(String, Element<'_>)>) -> Vec<(String, Element<'_>)> {
    let mut set = HashSet::new();
    values
        .iter()
        .filter(|(v, _)| set.insert(v.to_string()))
        .cloned()
        .collect()
}

#[allow(non_snake_case)]
pub fn Select<'a>(props: 'a, Props<'a>) -> Element {
    let initial_value = props.initial_value.clone();
    let mut options = remove_duplicates(props.options.clone());
    options.retain(|value| value != &initial_value);
    options.insert(0, initial_value.clone());
    let iter = IntoIterator::into_iter(options.clone());

    // TODO: We should iterate through the options and figure out the maximum length of an option
    // use this to calculate the min-width of the selectbox. Our max width should always be 100%.
    rsx!(
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

#[derive(Props)]
pub struct FancySelectProps<'a> {
    #[props(optional)]
    _loading: Option<bool>,
    options: Vec<(String, Element)>,
    #[props(optional)]
    onselect: Option<EventHandler<String>>,
    initial_value: (String, Element),
    current_to_top: Option<bool>,
    width: i32,
}

#[allow(non_snake_case)]
pub fn FancySelect<'a>(props: 'a, FancySelectProps<'a>) -> Element {
    let (initial_value, initial_element) = props.initial_value.clone();
    let mut options = remove_duplicates_fancy(props.options.clone());
    if props.current_to_top.unwrap_or_default() {
        options.retain(|(key, _)| key != &initial_value);
        options.insert(0, (initial_value.clone(), initial_element.clone()))
    };
    let iter = IntoIterator::into_iter(options.clone());
    let visible = use_ref(cx, || false);

    // TODO: We should iterate through the options and figure out the maximum length of an option
    // use this to calculate the min-width of the selectbox. Our max width should always be 100%.
    rsx!(
        div {
            class: "select",
            aria_label: "Selector",
            div {
                class: "fancy-select-wrap",
                position: "relative",
                width: format_args!("{}px", props.width),
                onclick: |e| {
                    let b = *visible.read();
                    *visible.write() = !b;
                    e.stop_propagation()
                },
                div {
                    class: "fancy-select",
                    initial_element
                },
                visible.read().then(||{
                    rsx!(
                        div {
                            class: "fancy-select-options",
                            aria_label: "selector-options-list",
                            iter.map(|(val, element)|
                                rsx!(div {
                                    class: "fancy-select-option",
                                    aria_label: "selector-option",
                                    onclick: move |e| {
                                        if let Some(f) = &props.onselect {
                                            f.call(val.clone())
                                        }
                                        visible.set(false);
                                        e.stop_propagation()
                                    },
                                    element
                                })
                            )
                        },
                        InvisibleCloser {
                            onclose: |_| {
                                visible.set(false);
                            }
                        }
                    )
                })
            }
        }
    ))
}
