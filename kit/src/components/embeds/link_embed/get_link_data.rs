use std::error::Error;

use reqwest::Url;
use scraper::{Html, Selector};

pub fn get_image_data(document: Html, meta_selector: Selector) -> Option<String> {
    let mut image = None;

    for element in document.select(&meta_selector) {
        let prop_attr_opt = element.value().attr("property");
        let content_attr_opt = element.value().attr("content");

        if let (Some(prop_attr), Some(content_attr)) = (prop_attr_opt, content_attr_opt) {
            if prop_attr == "og:image" {
                image = Some(content_attr.to_string());
                if !image.clone().unwrap_or_default().is_empty() {
                    break;
                }
            }
        }
    }

    image
}

pub fn get_title_data(document: Html, meta_selector: Selector) -> String {
    let title_selector = match Selector::parse("title") {
        Ok(data) => data,
        Err(_) => return String::new(),
    };

    let mut title = String::new();

    for element in document.select(&meta_selector) {
        let prop_attr_opt = element.value().attr("property");
        let content_attr_opt = element.value().attr("content");

        if let (Some(prop_attr), Some(content_attr)) = (prop_attr_opt, content_attr_opt) {
            if prop_attr == "og:title" {
                title = content_attr.to_string();
                if !title.is_empty() {
                    break;
                }
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

pub fn get_description_data(document: Html, meta_selector: Selector) -> String {
    let mut description = String::new();

    for element in document.select(&meta_selector) {
        let prop_attr_opt = element.value().attr("property");
        let name_attr_opt = element.value().attr("name");
        let content_attr_opt = element.value().attr("content");

        if let (Some(prop_attr), Some(content_attr)) = (prop_attr_opt, content_attr_opt) {
            if prop_attr == "og:description" {
                description = content_attr.to_string();
                if !description.is_empty() {
                    break;
                }
            }
        }

        if description.is_empty() {
            if let (Some(name_attr), Some(content_attr)) = (name_attr_opt, content_attr_opt) {
                if name_attr == "description" {
                    description = content_attr.to_string();
                    if !description.is_empty() {
                        break;
                    }
                }
            }
        }
    }

    description
}

pub async fn fetch_icon(url: &str, document: Html) -> Result<Option<String>, Box<dyn Error>> {
    let selectors = vec![
        r#"link[rel="icon"]"#,
        r#"link[rel="shortcut icon"]"#,
        r#"link[rel="apple-touch-icon"]"#,
        r#"link[rel="apple-touch-icon-precomposed"]"#,
        r#"link[rel="mask-icon"]"#,
        r#"link[rel="fluid-icon"]"#,
        r#"meta[name="msapplication-TileImage"]"#,
        r#"link[rel="manifest"]"#,
        r#"meta[property="twitter:image"]"#,
    ];

    let base_url = Url::parse(url)?;

    for selector_str in selectors {
        let selector = Selector::parse(selector_str)?;
        if let Some(element) = document.select(&selector).next() {
            let attr = match selector_str {
                r#"link[rel="manifest"]"# => "src",
                _ => "href",
            };
            if let Some(path) = element.value().attr(attr) {
                let full_url = base_url.join(path)?.to_string();
                let resp = reqwest::get(&full_url).await?;
                if resp.status().is_success() {
                    return Ok(Some(full_url));
                }
            }
        }
    }

    Ok(None)
}
