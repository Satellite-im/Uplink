var APPLY_FOCUS = $APPLY_FOCUS
var MULTI_LINE = $MULTI_LINE

if (APPLY_FOCUS) {
    var input_element = document.getElementById('UUID')
    input_element.focus()
}

var textareas = document.getElementsByClassName("input_textarea");
for (let i = 0; i < textareas.length; i++) {
    var txt = textareas[i]
    txt.addEventListener("input", e => updateHeight(txt))
    txt.addEventListener("keypress", function (e) {
        if (e.key == "Enter") {
            e.preventDefault()
            //Doing this in js instead of rust to properly update the textarea height
            //Maybe someone else has an idea of updating the height via dioxus
            if (MULTI_LINE && e.shiftKey) {
                txt.value += "\n"
                var inputEvent = new Event("input")
                txt.dispatchEvent(inputEvent)
            }
        }
    });
}

function updateHeight(txt) {
    txt.style.height = "0px"
    txt.style.height = txt.scrollHeight + "px"
}