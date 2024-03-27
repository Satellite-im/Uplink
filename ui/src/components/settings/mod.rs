use common::icons::outline::Shape as Icon;
use common::icons::Icon as IconElement;
use dioxus::prelude::*;
use kit::elements::label::Label;

pub mod sidebar;
pub mod sub_pages;

#[derive(Props, Clone, PartialEq)]
pub struct SectionProps {
    section_label: String,
    section_description: String,
    aria_label: Option<String>,
    #[props(default)]
    no_border: bool,
    children: Element,
}

#[allow(non_snake_case)]
pub fn SettingSection(props: SectionProps) -> Element {
    let aria_label = props.aria_label.clone().unwrap_or_default();
    let no_border = props.no_border.then_some("no-border").unwrap_or_default();

    rsx!(
        div {
            class: "settings-section disable-select {no_border}",
            aria_label: "{aria_label}",
            div {
                class: "settings-info",
                aria_label: "settings-info",
                Label {
                    text: props.section_label.clone(),
                },
                p {
                    "{props.section_description}"
                }
            },
            {props.children.is_some().then(|| rsx!(
                div {
                    class: "settings-control",
                    aria_label: "settings-control",
                    {&props.children}
                }
            ))}
        }
    )
}

#[derive(Props, Clone, PartialEq)]
pub struct SectionSimpleProps {
    aria_label: Option<String>,
    children: Element,
}
#[allow(non_snake_case)]
pub fn SettingSectionSimple(props: SectionSimpleProps) -> Element {
    let aria_label = props.aria_label.clone().unwrap_or_default();
    rsx!(
        div {
            class: "settings-section simple disable-select",
            aria_label: "{aria_label}",
            {props.children.is_some().then(|| rsx!(
                div {
                    class: "settings-control",
                    aria_label: "settings-control",
                    {&props.children}
                }
            ))}
        }
    )
}

#[derive(Props, Clone, PartialEq)]
pub struct ExtensionProps {
    title: String,
    author: String,
    description: String,
    children: Element,
}

#[allow(non_snake_case)]
pub fn ExtensionSetting(props: ExtensionProps) -> Element {
    rsx!(
        div {
            class: "extension-setting",
            aria_label: "extension-setting-element",
            div {
                class: "heading",
                IconElement {
                    icon: Icon::Beaker
                },
                div {
                    class: "text",
                    p {
                        aria_label: "extension-setting-title",
                        class: "title",
                        "{props.title}"
                    },
                    Label {
                        aria_label: "extension-setting-author".to_string(),
                        text: props.author.clone(),
                    }
                },
                div {
                    class: "control",
                    {&props.children}
                }
            },
            p {
                class: "description",
                aria_label: "extension-setting-description",
                "{props.description}"
            }
        }
    )
}
