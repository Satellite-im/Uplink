function observe_list() {
    var send_top_event = $SEND_TOP_EVENT;
    var send_bottom_event = $SEND_BOTTOM_EVENT;
    var conversation_id = $CONVERSATION_ID;
    console.log("send_top_event is " + send_top_event);
    console.log("send_bottom_event is " + send_bottom_event);
    
    var observer3 = new IntersectionObserver( (entries, observer) => {
        entries.forEach((entry) => {
            if (entry.isIntersecting) {
                dioxus.send("{\"Add\":{\"msg_id\":" + entry.target.id + ",\"conv_id\":" + conversation_id + "}}");
                if (!entry.target.nextElementSibling && send_bottom_event) {
                    dioxus.send("{\"Bottom\":{\"conv_id\":" + conversation_id + "}}");
                    observer.disconnect();
                } else if (!entry.target.previousElementSibling && send_top_event) {
                    dioxus.send("{\"Top\":{\"conv_id\":" + conversation_id + "}}");
                    observer.disconnect();
                }
            } else {
                dioxus.send("{\"Remove\":" + entry.target.id + ",\"conv_id\":" + conversation_id + "}}");
            }
        });
    }, {
        root: null,
        rootMargin: "0px",
        threshold: 0.75,
    });
    const elements = document.querySelectorAll("#compose-list > li");
    elements.forEach( (element) => {
        let id = "#" + element.id;
        observer3.observe(element);
    });
}

observe_list();