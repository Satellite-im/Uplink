var MULTI_LINE = $MULTI_LINE;

var sendButton = document.getElementsByClassName("controls")
var textareas = document.getElementsByClassName("input_textarea")
for (let i = 0; i < textareas.length; i++) {
    var txt = textareas[i];
    //Update the height on load
    updateHeight(txt);
    if (!txt.event_listener) {
        txt.addEventListener("input", inputListener);
        txt.addEventListener("keypress", keyPressListener);
        txt.addEventListener("keydown", arrowHandlerListener);
        txt.event_listener = true;
        if (i == 0) {
            txt.addEventListener("keypress", (event) => {
            if (event.keyCode === 13 && !event.shiftKey) {
              textareas[0].style.height = "22px";
              textareas[0].value = "";
            }
          });
        }
    }
}

sendButton[1].addEventListener("click", (event) => {
    textareas[0].style.height = "22px";
    textareas[0].value = "";
})

if (textareas[0].style.height === "66px") {
    textareas[0].style.height = "22px";
}

function inputListener(e) {
    updateHeight(this);
}

function updateHeight(element) {
    element.style.height = "auto";
    if (!element.value || MULTI_LINE) {
        element.style.height = "0px";
    }
    element.style.height = element.scrollHeight + "px";
}
function keyPressListener(e) {
    if (e.key == "Enter" && MULTI_LINE && !e.shiftKey) {
        e.preventDefault();
    } 
}

function arrowHandlerListener(e) {
    if (this.classList.contains("up-down-disabled") && (e.key == "ArrowUp" || e.key == "ArrowDown")) {
        e.preventDefault();
    } 
}
