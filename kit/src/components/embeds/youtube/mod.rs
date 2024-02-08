use dioxus::prelude::*;

#[derive(Eq, PartialEq, Props)]
pub struct Props {
    video_url: String,
}

#[allow(non_snake_case)]
pub fn YouTubePlayer(cx: Scope<Props>) -> Element {
    let src_video = match extract_video_id_from_embed_url(&cx.props.video_url) {
        Some(video_id) => format!("https://www.youtube.com/embed/{}", video_id),
        None => cx.props.video_url.clone(),
    };

    cx.render(rsx!(
        div {
            id: "youtube-player",
            iframe {
                src: "{src_video}",
                frame_border: "0",
                allow: "accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture",
                allowfullscreen: true,
            },
        }
    ))
}

fn extract_video_id_from_embed_url(embed_url: &str) -> Option<String> {
    let base_embed_url = "https://www.youtube.com/embed/";

    if let Some(video_id_with_params) = embed_url.strip_prefix(base_embed_url) {
        let video_id = match video_id_with_params.find('&') {
            Some(end_pos) => &video_id_with_params[..end_pos],
            None => video_id_with_params,
        };
        return Some(video_id.to_string());
    }
    None
}
