use common::icons::outline::Shape as Icon;
use common::icons::Icon as IconElement;
use dioxus::prelude::*;

#[derive(Props)]
pub struct Props<'a> {
    disabled: bool,
    width: Option<String>,
    height: Option<String>,
    // if the checkbox is in a row and it is desired that clicking the row
    // triggers the click event, this hook lets that happen.
    // please don't create the hook on the fly. Creating Elements, which define a single hook, on the fly is OK.
    is_checked: bool,
    // returns true if the box is selected, false otherwise
    on_click: EventHandler<()>,
    aria_label: Option<String>,
}

#[allow(non_snake_case)]
pub fn Checkbox<'a>(props: Props<'a>) -> Element {
    let disabled_class = if props.disabled { "disabled" } else { "" };
    let checked_class = if props.is_checked { "checked" } else { "" };
    let aria_label = props.aria_label.clone().unwrap_or_default();

    let height = cx
        .props
        .height
        .clone()
        .unwrap_or_else(|| "fit-content".into());
    let width = cx
        .props
        .width
        .clone()
        .unwrap_or_else(|| "fit-content".into());

    cx.render(rsx!(
            div {
            aria_label: "{aria_label}",
            class: "input-checkbox {checked_class} {disabled_class} ",
            height: "{height}",
            width: "{width}",
            onclick: move |_| {
                props.on_click.call(());
            },
            props.is_checked.then(|| {
                rsx!(
                    IconElement {
                        icon: Icon::Check
                    }
                )
            }),
        }
    ))
}
