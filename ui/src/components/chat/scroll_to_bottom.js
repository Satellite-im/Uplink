const chat = document.getElementById("messages")
const lastChild = chat.lastElementChild
chat.scrollTop = chat.scrollHeight
lastChild.scrollIntoView({ behavior: 'smooth', block: 'end' })