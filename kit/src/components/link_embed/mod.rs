use dioxus::prelude::*;
use dioxus::prelude::{rsx, Props};
use dioxus_core::{Element, Scope};
use dioxus_hooks::use_future;
use select::document::Document;
use select::predicate::Name;

#[derive(Default, Debug, Clone, Eq, PartialEq)]
pub struct SiteMeta {
    pub title: String,
    pub description: String,
    pub icon: String,
    pub url: String,
}

pub async fn get_meta(url: &str) -> Result<SiteMeta, reqwest::Error> {
    let content = reqwest::get(url).await?.text().await?;

    let doc = Document::from(content.as_str());
    let title = doc
        .find(Name("title"))
        .next()
        .map(|node| node.text())
        .unwrap_or_default();

    let desc = doc
        .find(Name("meta"))
        .filter_map(|n| {
            let attr = n.attr("name");
            let is_desc = match attr {
                Some(v) => {
                    if v.eq("description") {
                        n.attr("content")
                    } else {
                        None
                    }
                }
                None => None,
            };
            is_desc
        })
        .next()
        .unwrap_or_default();

    let icon = doc
        .find(Name("link"))
        .filter_map(|n| {
            let attr = n.attr("rel");
            let is_desc = match attr {
                Some(v) => {
                    if v.eq("icon") {
                        n.attr("href")
                    } else {
                        None
                    }
                }
                None => None,
            };
            is_desc
        })
        .next()
        .unwrap_or_default();

    Ok(SiteMeta {
        title,
        description: String::from(desc),
        icon: String::from(icon),
        url: String::from(url),
    })
}

#[derive(Props, PartialEq)]
pub struct LinkEmbedProps {
    link: String,
    remote: bool,
}

#[allow(non_snake_case)]
pub fn EmbedLinks(cx: Scope<LinkEmbedProps>) -> Element {
    let fetch_meta = use_future(cx, &cx.props.link, |link| async move {
        get_meta(link.as_str()).await
    });

    let meta = match fetch_meta.value() {
        Some(Ok(val)) => val.clone(),
        Some(Err(_)) => SiteMeta::default(),
        None => SiteMeta::default(),
    };

    let title = if meta.title.chars().count() > 100 {
        meta.title[0..97].to_string() + "..."
    } else {
        meta.title.clone()
    };

    let desc = if meta.description.chars().count() > 200 {
        meta.description[0..197].to_string() + "..."
    } else {
        meta.description.clone()
    };

    cx.render(rsx! {
        if meta.title.is_empty() {
            rsx! { span {""} }
        } else {
            rsx! {
                div {
                    class: format_args!("link-embed-container {}", if cx.props.remote {"link-embed-remote"} else {""}),
                    div {
                        class: "link-embed",
                        div {
                            class: "embed-icon",
                            img {
                                src: "{meta.icon}"
                            },
                            a {
                                class: "link-title",
                                href: "{cx.props.link}",
                                "{title}"
                            }
                        },
                        h2 {},
                        div {
                            class: "embed-details",
                            p {
                                "{desc}"
                            }
                        }
                    }
                }
            }
        }
    })
}
