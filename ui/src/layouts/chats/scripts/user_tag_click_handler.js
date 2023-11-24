let tags = document.getElementsByClassName("message-user-tag")
for (var i = 0; i < tags.length; i++) {
    let element = tags.item(i)
    if (!element.hasUserTagEvent) {
        element.hasUserTagEvent = true;
        element.addEventListener("click", (e) => {
            let did = element.getAttribute("value")
            dioxus.send(`[${e.clientX}, ${e.clientY}, "${did}"]`)
        });
    }
}