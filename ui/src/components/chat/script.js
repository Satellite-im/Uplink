var chat = document.getElementById("messages")
var lastChild = chat.lastElementChild
chat.scrollTop = chat.scrollHeight
lastChild.scrollIntoView({ behavior: 'smooth', block: 'end' })