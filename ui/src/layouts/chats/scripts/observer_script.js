function observe_list() {
    var send_top_event = $SEND_TOP_EVENT;
    var send_bottom_event = $SEND_BOTTOM_EVENT;
    var msg_view = document.getElementById("messages");
    var view_height = msg_view.getBoundingClientRect().height * 0.8;
    var conversation_key = "$CONVERSATION_KEY";
    var top_msg_id = "$TOP_MSG_ID";
    var bottom_msg_id = "$BOTTOM_MSG_ID";
    console.log("send_top_event is " + send_top_event);
    console.log("send_bottom_event is " + send_bottom_event);
    const callback = (entries, observer) => {
        const el = document.getElementById(conversation_key);
        if  (!el) {
            observer.disconnect();
            observer = null;
            return;
        }
        entries.forEach((entry) => {
            if (entry.isIntersecting) {
                dioxus.send("{\"Add\":{\"msg_id\":\"" + entry.target.id + "\",\"key\":\"" + conversation_key + "\"}}");
                if (entry.target.id == bottom_msg_id && send_bottom_event) {
                    dioxus.send("{\"Bottom\":{\"key\":\"" + conversation_key + "\"}}");
                    observer.disconnect();
                    observer = null;
                    return;
                } else if (entry.target.id == top_msg_id && send_top_event) {
                    dioxus.send("{\"Top\":{\"key\":\"" + conversation_key + "\"}}");
                    observer.disconnect();
                    observer = null;
                    return;
                }
            } else {
                dioxus.send("{\"Remove\":{\"msg_id\":\"" + entry.target.id + "\",\"key\":\"" + conversation_key + "\"}}");
            }
        });
    };
    var observer = new IntersectionObserver(callback, {
        root: msg_view,
        rootMargin: "4px",
        threshold: 0.95,
    });
    const elements = document.querySelectorAll("#messages div.message-group > div.context-wrap > div.context-inner");
    elements.forEach( (element) => {
        let id = "#" + element.id;
        var element_height = element.getBoundingClientRect().height;
        if (element_height > view_height) {
            var threshold = Math.max(0, view_height / element_height - 0.05 )
            new IntersectionObserver(callback, {
                root: msg_view,
                rootMargin: "40px",
                threshold: threshold,
            }).observe(element)
        } else {
            observer.observe(element);
        }
    });
}

observe_list();