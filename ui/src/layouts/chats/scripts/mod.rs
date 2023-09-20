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
