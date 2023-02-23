var APPLY_FOCUS
if (APPLY_FOCUS) {
    var input_element = document.getElementById('UUID')
    input_element.focus()
}

var textareas = document.getElementsByClassName("input_textarea");
for (let i = 0; i < textareas.length; i++) {
    textareas[i].setAttribute("style", "height:" + (textareas[i].scrollHeight) + "px;overflow-y:hidden;")
    textareas[i].addEventListener("input", function (e) {
        this.style.height = "auto"
        this.style.height = this.scrollHeight + "px"
    });
    textareas[i].addEventListener("keypress", function (e) {
        if (e.key == "Enter") {
            e.preventDefault()
        }
    });
}