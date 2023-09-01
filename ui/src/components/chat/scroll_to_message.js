var message = document.getElementById("message-$UUID-false")
message.scrollIntoView({ behavior: 'smooth', block: 'end' })

var parent = message.parentElement;

parent.classList.add("background-highlight");
setTimeout(function() {
    parent.classList.remove("background-highlight")
}, 2 * 1000);