function observe_list() {
    var send_top_event = $SEND_TOP_EVENT;
    var send_bottom_event = $SEND_BOTTOM_EVENT;
    var conversation_key = "$CONVERSATION_KEY";
    var top_msg_id = "$TOP_MSG_ID";
    var bottom_msg_id = "$BOTTOM_MSG_ID";
    console.log("send_top_event is " + send_top_event);
    console.log("send_bottom_event is " + send_bottom_event);
    
    var observer = new IntersectionObserver( (entries, observer) => {
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
    }, {
        root: null,
        rootMargin: "0px",
        threshold: 0.05,
    });
    const elements = document.querySelectorAll("#messages div.message-group > div.context-wrap > div.context-inner");
    elements.forEach( (element) => {
        let id = "#" + element.id;
        observer.observe(element);
    });
}

observe_list();