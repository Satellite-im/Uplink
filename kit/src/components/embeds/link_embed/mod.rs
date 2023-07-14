use std::path::Path;

use dioxus::prelude::*;
use dioxus::prelude::{rsx, Props};
use dioxus_core::{Element, Scope};
use dioxus_hooks::use_future;
use reqwest::Url;
use scraper::{Html, Selector};
use select::document::Document;
use select::predicate::Name;

use crate::components::embeds::youtube::YouTubePlayer;

#[derive(Default, Debug, Clone, Eq, PartialEq)]
pub struct SiteMeta {
    pub title: String,
    pub description: String,
    pub icon: String,
    pub url: String,
}

pub async fn get_meta(url: &str) -> Result<SiteMeta, reqwest::Error> {
    let content = reqwest::get(url).await?.text().await?;

    let fav_icon = get_icon_data(&content).await.1.unwrap_or_default();
    let image_data = get_image_data(&content).await.unwrap_or_default();
    let title = get_title_data(&content).await;
    let description = get_description_data(&content).await;

    let icon_src = match Url::parse(&fav_icon) {
        Ok(_) => fav_icon,
        Err(_) => image_data.clone(),
    };

    Ok(SiteMeta {
        title,
        description: description,
        icon: icon_src,
        url: String::from(url),
    })
}

async fn get_image_data(content: &str) -> Option<String> {
    let document = Html::parse_document(&content);
    let selector = Selector::parse("meta").unwrap();
    let mut image = None;

    for element in document.select(&selector) {
        let prop_attr_opt = element.value().attr("property");
        let content_attr_opt = element.value().attr("content");

        if let (Some(prop_attr), Some(content_attr)) = (prop_attr_opt, content_attr_opt) {
            if prop_attr == "og:image" {
                image = Some(content_attr.to_string());
            }
        }
    }

    image
}

async fn get_icon_data(content: &str) -> (Option<String>, Option<String>) {
    let document = Html::parse_document(&content);
    let selector = Selector::parse("link").unwrap();
    let mut apple_icon = None;
    let mut fav_icon = None;

    for element in document.select(&selector) {
        let rel_attr_opt = element.value().attr("rel");
        let href_attr_opt = element.value().attr("href");

        if let (Some(rel_attr), Some(href_attr)) = (rel_attr_opt, href_attr_opt) {
            if rel_attr == "apple-touch-icon" {
                apple_icon = Some(href_attr.to_string());
            } else if rel_attr.contains("icon") {
                fav_icon = Some(href_attr.to_string());
            }
        }
    }

    (apple_icon, fav_icon)
}

async fn get_title_data(content: &str) -> String {
    let document = Html::parse_document(&content);
    let meta_selector = Selector::parse("meta").unwrap();
    let title_selector = Selector::parse("title").unwrap();

    let mut title = String::new();

    for element in document.select(&meta_selector) {
        let prop_attr_opt = element.value().attr("property");
        let content_attr_opt = element.value().attr("content");

        if let (Some(prop_attr), Some(content_attr)) = (prop_attr_opt, content_attr_opt) {
            if prop_attr == "og:title" {
                title = content_attr.to_string();
            }
        }
    }

    if title.is_empty() {
        if let Some(element) = document.select(&title_selector).next() {
            title = element.inner_html();
        }
    }

    title
}

async fn get_description_data(content: &str) -> String {
    let document = Html::parse_document(&content);
    let meta_selector = Selector::parse("meta").unwrap();

    let mut description = String::new();

    for element in document.select(&meta_selector) {
        let prop_attr_opt = element.value().attr("property");
        let name_attr_opt = element.value().attr("name");
        let content_attr_opt = element.value().attr("content");

        if let (Some(prop_attr), Some(content_attr)) = (prop_attr_opt, content_attr_opt) {
            if prop_attr == "og:description" {
                description = content_attr.to_string();
            }
        }

        if description.is_empty() {
            if let (Some(name_attr), Some(content_attr)) = (name_attr_opt, content_attr_opt) {
                if name_attr == "description" {
                    description = content_attr.to_string();
                }
            }
        }
    }

    description
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

    let youtube_video = if cx.props.link.contains("youtube.com/watch?v=") {
        Some(cx.props.link.replace("watch?v=", "embed/"))
    } else {
        None
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
                        aria_label: "link-embed",
                        div {
                            class: "embed-icon",
                            aria_label: "embed-icon",
                            img {
                                src: "{meta.icon}",
                                alt: "Website Icon",
                            },
                            if !title.is_empty() {
                                rsx!(a {
                                    class: "link-title",
                                    aria_label: "link-title",
                                    href: "{cx.props.link}",
                                    "{title}"
                                })
                            }
                            
                        },
                        if desc.is_empty() && youtube_video.is_none() {
                            rsx!(div {})
                        } else {
                            rsx!( div {
                                class: "embed-details",
                                aria_label: "embed-details",
                                youtube_video.is_some().then(|| rsx!(
                                    YouTubePlayer {
                                        video_url: youtube_video.unwrap(),
                                    }
                                ))
                                p {
                                    "{desc}"
                                }
                            })
                        }
                    }
                }
            }
        }
    })
}
