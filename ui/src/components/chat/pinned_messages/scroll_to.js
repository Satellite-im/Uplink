var message = document.getElementById("message-$UUID-false")
message.scrollIntoView({ behavior: 'smooth', block: 'end' })
var pinned = document.getElementById("pinned-messages-container")
pinned.classList.add("hidden")

var parent = message.parentElement;

parent.classList.add("background-highlight");
setTimeout(function() {
    parent.classList.remove("background-highlight")
}, 2 * 1000);