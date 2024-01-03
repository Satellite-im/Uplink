use dioxus::prelude::*;

#[derive(Eq, PartialEq, Props)]
pub struct Props {
    video_url: String,
}

#[allow(non_snake_case)]
pub fn YouTubePlayer(cx: Scope<Props>) -> Element {
    cx.render(
        rsx!(
            div {
                id: "youtube-player",
                iframe {
                    src: "{cx.props.video_url}",
                    allow: "accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture",
                    allowfullscreen: true,
                },
            }
        )
    )
}
