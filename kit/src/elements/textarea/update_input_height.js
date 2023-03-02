var textareas = document.getElementsByClassName("input_textarea");
for (let i = 0; i < textareas.length; i++) {
    var txt = textareas[i]
    txt.style.height = "0px"
    txt.style.height = txt.scrollHeight + "px"
}
