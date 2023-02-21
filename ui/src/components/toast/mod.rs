use common::icons::outline::Shape as Icon;
use common::state::State;
use dioxus::prelude::*;
use kit::elements::Appearance;
use uuid::Uuid;

#[derive(PartialEq, Props)]
pub struct Props {
    id: Uuid,
    #[props(optional)]
    icon: Option<Icon>,
    #[props(optional)]
    with_title: Option<String>,
    #[props(optional)]
    with_content: Option<String>,
    #[props(optional)]
    appearance: Option<Appearance>,
}

#[allow(non_snake_case)]
pub fn Toast(cx: Scope<Props>) -> Element {
    let state: UseSharedState<State> = use_shared_state::<State>(cx).unwrap();
    cx.render(rsx!(kit::components::toast::Toast {
        id: cx.props.id,
        on_hover: move |_| state.write_silent().reset_toast_timer(&cx.props.id),
        on_close: move |_| state.write().remove_toast(&cx.props.id),
        icon: cx.props.icon,
        with_title: cx.props.with_title.clone(),
        with_content: cx.props.with_content.clone(),
        appearance: cx.props.appearance
    }))
}
