
const chat = document.getElementById("messages")
if ($SCROLL_TO) {
    chat.scrollTo(0, $VALUE)
}
else if ($SCROLL_UNREAD){
    const child = chat.children[chat.childElementCount - $UNREADS]
    chat.scrollTop = chat.scrollHeight
    child.scrollIntoView({ behavior: 'smooth', block: 'end' })
} else {
    const lastChild = chat.lastElementChild
    chat.scrollTop = chat.scrollHeight
    lastChild.scrollIntoView({ behavior: 'smooth', block: 'end' })
}