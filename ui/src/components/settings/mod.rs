use common::icons::outline::Shape as Icon;
use common::icons::Icon as IconElement;
use dioxus::prelude::*;
use kit::elements::label::Label;

pub mod sidebar;
pub mod sub_pages;
#[derive(Props)]
pub struct SectionProps<'a> {
    section_label: String,
    section_description: String,
    children: Element<'a>,
}

#[allow(non_snake_case)]
pub fn SettingSection<'a>(cx: Scope<'a, SectionProps<'a>>) -> Element<'a> {
    cx.render(rsx!(
        div {
            class: "settings-section",
            aria_label: "settings-section",
            div {
                class: "settings-info",
                aria_label: "settings-info",
                Label {
                    text: cx.props.section_label.clone(),
                },
                p {
                    "{cx.props.section_description}"
                }
            },
            cx.props.children.is_some().then(|| rsx!(
                div {
                    class: "settings-control",
                    aria_label: "settings-control",
                    &cx.props.children
                }
            ))
        }
    ))
}

#[derive(Props)]
pub struct ExtensionProps<'a> {
    title: String,
    author: String,
    description: String,
    children: Element<'a>,
}

#[allow(non_snake_case)]
pub fn ExtensionSetting<'a>(cx: Scope<'a, ExtensionProps<'a>>) -> Element<'a> {
    cx.render(rsx!(
        div {
            class: "extension-setting",
            div {
                class: "heading",
                IconElement {
                    icon: Icon::Beaker
                },
                div {
                    class: "text",
                    p {
                        class: "title",
                        "{cx.props.title}"
                    },
                    Label {
                        text: cx.props.author.clone(),
                    }
                },
                div {
                    class: "control",
                    &cx.props.children
                }
            },
            p {
                class: "description",
                "{cx.props.description}"
            }
        }
    ))
}
