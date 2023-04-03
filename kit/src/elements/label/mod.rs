use dioxus::prelude::*;

#[derive(PartialEq, Eq, Clone, Default)]
pub struct LabelWithEllipsis {
    pub apply_ellipsis: bool,
    pub padding_rigth_for_ellipsis: usize,
}

#[derive(PartialEq, Eq, Props)]
pub struct Props {
    #[props(optional)]
    loading: Option<bool>,
    #[props(optional)]
    label_with_ellipsis: Option<LabelWithEllipsis>,
    text: String,
}

#[allow(non_snake_case)]
pub fn Label(cx: Scope<Props>) -> Element {
    let (apply_ellipsis, padding_right) =
        if let Some(label_with_ellipsis) = cx.props.label_with_ellipsis.clone() {
            (
                label_with_ellipsis.apply_ellipsis,
                label_with_ellipsis.padding_rigth_for_ellipsis,
            )
        } else {
            (false, 0)
        };

    cx.render(rsx!(
        label {
            class: if apply_ellipsis {"wrap-text"} else {""},
            padding_right: "{padding_right}px",
            "{cx.props.text}"
        }
    ))
}
