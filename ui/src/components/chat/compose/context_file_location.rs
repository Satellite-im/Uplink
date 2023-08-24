pub struct FileLocationProps<'a> {
    id: &'a String,
    did_key: DID,
    update_script: &'a UseState<String>,
    children: Element<'a>,
}

#[allow(non_snake_case)]
pub fn FileLocationContext<'a>(cx: Scope<'a, QuickProfileProps<'a>>) -> Element<'a> {
    cx.render(rsx!(ContextMenu {
        id: format!("{id}"),
        items: cx.render(rsx!(
            IdentityHeader {
                sender_did: identity.did_key()
            },
            hr {},
            ContextItem {
                icon: Icon::UserCircle,
                aria_label: "quick-profile-self-edit".into(),
                text: "Disk".into(),
                onpress: move |_| {}
            },
            ContextItem {
                icon: Icon::UserCircle,
                aria_label: "quick-profile-self-edit".into(),
                text: "Uplink".into(),
                onpress: move |_| {}
            }
        ))
    }))
}
