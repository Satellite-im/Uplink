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

pub const SHOW_CONTEXT: &str = r#"
let xPadding = 30
let yPadding = 10

var menus = document.getElementsByClassName("context-menu")
for (var i = 0; i < menus.length; i++) {
  menus.item(i).classList.add("hidden")
}
// Select the current one
var context_menu = document.getElementById("UUID-context-menu")
context_menu.classList.remove("hidden")
var { width, height } = context_menu.getBoundingClientRect()
// The offset coords using the clicked position as absolute screen coords
let offsetX = $PAGE_X + xPadding
let offsetY = $PAGE_Y - yPadding + height
// Sizes of the whole app screen
let screenWidth = window.innerWidth || document.documentElement.clientWidth
let screenHeight = window.innerHeight || document.documentElement.clientHeight

let overFlowY = offsetY + yPadding > screenHeight
context_menu.style = ""
context_menu.style.position = "absolute"
context_menu.style.bottom = `${overFlowY ? yPadding : screenHeight - offsetY}px`
if ($SELF) {
  context_menu.style.right = `${screenWidth - offsetX}px`
} else {
  // The context menu should be relative to the parents dimensions
  let parentRect = context_menu.parentElement.parentElement.getBoundingClientRect()
  let parentOffsetX = parentRect.left
  context_menu.style.left = `${offsetX - parentOffsetX}px`
}
"#;

pub const SCROLL_TO_MESSAGE: &str = r#"
var message = document.getElementById("message-$UUID-false")
message.scrollIntoView({ behavior: 'smooth', block: 'end' })

var parent = message.parentElement;

parent.classList.add("background-highlight");
setTimeout(function() {
    parent.classList.remove("background-highlight")
}, 2 * 1000);
"#;

// returns for eval
pub const SCROLL_TO_ID: &str = r#"
var message = document.getElementById("$MESSAGE_ID");
message.scrollIntoView({ behavior: 'instant', block: 'start' });
return "done";
"#;

// returns for eval
pub const SCROLL_TO_END: &str = r#"
window.scrollTo(0, document.body.scrollHeight); 
return "done";
"#;

pub const OBSERVER_SCRIPT: &str = r###"
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
"###;
