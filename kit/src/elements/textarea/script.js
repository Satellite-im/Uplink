var APPLY_FOCUS = $APPLY_FOCUS;
var MULTI_LINE = $MULTI_LINE;

if (APPLY_FOCUS) {
    var input_element = document.getElementById('UUID');
    input_element.focus();
}

var textareas = document.getElementsByClassName("input_textarea")
for (let i = 0; i < textareas.length; i++) {
    var txt = textareas[i];
    //Update the height on load
    updateHeight(txt)
    if (!txt.event_listener) {
        txt.addEventListener("input", inputListener);
        txt.addEventListener("keypress", keyPressListener);
        txt.event_listener = true;
    }
}

function inputListener(e) {
    updateHeight(this);
}

function updateHeight(element) {
    element.style.height = "auto"
    if (!element.value || MULTI_LINE) {
        element.style.height = "0px";
    }
    element.style.height = element.scrollHeight + "px";
}

function keyPressListener(e) {
    if (e.key == "Enter") {
        e.preventDefault();
        //Doing this in js instead of rust to properly update the textarea height
        //Maybe someone else has an idea of updating the height via dioxus
        if (MULTI_LINE && e.shiftKey) {
            this.value += "\n";
            //Scheduling an input event to properly update scroll height and textarea height
            var inputEvent = new Event("input");
            this.dispatchEvent(inputEvent);
        }
    }
}