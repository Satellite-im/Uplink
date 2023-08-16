var pinned = document.getElementById("pinned-messages-container")
pinned.classList.add("hidden")

var message = document.getElementById("message-$UUID-false")
if (!message) {
    // If message is not loaded simply go to the top?
    var messages = document.getElementsByClassName("message-group")[0]
    var top_message_container = messages.childNodes[0].childNodes;
    for(var i=0; i < top_message_container.length; i++){
        if (top_message_container[i].id.startsWith("message")) {
            message =  top_message_container[i];
            break;
        }
    }
}
message.scrollIntoView({ behavior: 'smooth', block: 'end' })

var parent = message.parentElement;

parent.classList.add("background-highlight");
setTimeout(function() {
    parent.classList.remove("background-highlight")
}, 2 * 1000);