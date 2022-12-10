pub mod chat {
    use dioxus::prelude::*;
    use ui_kit::{elements::input::{Input, Options}, icons::Icon, components::nav::Nav, layout::sidebar::Sidebar};

    use crate::layouts::chat::RouteInfo;

    #[derive(PartialEq, Props)]
    pub struct Props {
        route_info: RouteInfo,
    }

    #[allow(non_snake_case)]
    pub fn ChatSidebar(cx: Scope<Props>) -> Element {
        let search_placeholder = String::from("Search...");

        cx.render(rsx!(
            Sidebar {
                with_search: cx.render(rsx!(
                    div {
                        class: "search-input",
                        Input {
                            placeholder: search_placeholder,
                            icon: Icon::MagnifyingGlass,
                            options: Options {
                                with_clear_btn: true,
                                ..Options::default()
                            }
                        }
                    }
                ))
                with_nav: cx.render(rsx!(
                    Nav {
                        routes: cx.props.route_info.routes.clone(),
                        active: cx.props.route_info.active.clone()
                    }
                ))
            }
        ))
    }
}