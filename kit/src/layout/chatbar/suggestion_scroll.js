var suggestions = document.getElementById("chatbar-suggestions")
var list = suggestions.getElementsByClassName("chatbar-suggestion-list")[0]
var selected = list.childNodes[$NUM]
selected.scrollIntoView({ behavior: 'smooth', block: 'end' })
