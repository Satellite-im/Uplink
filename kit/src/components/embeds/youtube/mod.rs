use dioxus::prelude::*;

#[derive(Eq, PartialEq, Props)]
pub struct Props {
    video_url: String,
}

#[allow(non_snake_case)]
pub fn YouTubePlayer(props: Props) -> Element {
    let src_video = match extract_video_id_from_embed_url(&props.video_url) {
        Some(embed_path) => embed_path,
        None => props.video_url.clone(),
    };

    cx.render(rsx!(
        div {
            id: "youtube-player",
            aria_label: "youtube-player",
            iframe {
                src: "{src_video}",
                aria_label: "{src_video}",
                allow: "accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture",
                allowfullscreen: true,
            },
        }
    ))
}

fn extract_video_id_from_embed_url(embed_url: &str) -> Option<String> {
    let base_embed_url = "https://www.youtube.com/embed/";
    let video_id_with_params = embed_url.strip_prefix(base_embed_url)?;
    let video_id = match video_id_with_params.find('&') {
        Some(end_pos) => &video_id_with_params[..end_pos],
        None => video_id_with_params,
    };
    Some(format!("{}{}", base_embed_url, video_id))
}
