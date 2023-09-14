pub const SETUP_CONTEXT_PARENT: &str = r#"
    const right_clickable = document.getElementsByClassName("has-context-handler")
    console.log("E", right_clickable)
    for (var i = 0; i < right_clickable.length; i++) {
        //Disable default right click actions (opening the inspect element dropdown)
        right_clickable.item(i).addEventListener("contextmenu",
        function (ev) {
        ev.preventDefault()
        })
    }
"#;

pub const SCROLL_TO: &str = r#"
    const chat = document.getElementById("messages")
    chat.scrollTo(0, $VALUE)
"#;

pub const SCROLL_UNREAD: &str = r#"
    const chat = document.getElementById("messages")
    const child = chat.children[chat.childElementCount - $UNREADS]
    chat.scrollTop = chat.scrollHeight
    child.scrollIntoView({ behavior: 'smooth', block: 'end' })
"#;

pub const SCROLL_BOTTOM: &str = r#"
    const chat = document.getElementById("messages")
    const lastChild = chat.lastElementChild
    chat.scrollTop = chat.scrollHeight
    lastChild.scrollIntoView({ behavior: 'smooth', block: 'end' })
"#;

pub const READ_SCROLL: &str = "return document.getElementById(\"messages\").scrollTop";
