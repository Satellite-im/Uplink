/*(() => {
    // Handle moving and hiding/showing tooltip
    const input_group = document.getElementById("input-group-$UUID");
    // parent: input, parent of parent: input-group
    // tooltip is child of input-group
    const tooltip = document.getElementById("tooltip-$UUID");

    if (input_group != null && tooltip != null) {
        input_group.addEventListener("mouseover", function (e) {
            tooltip.classList.remove("hidden");
            tooltip.classList.add("visible");
            tooltip.style.position = "fixed";
            tooltip.style.left = e.clientX + "px";
            tooltip.style.top = (e.clientY - 50) + "px";
        })
        input_group.addEventListener("mousemove", function (e) {
            tooltip.style.position = "fixed";
            tooltip.style.left = e.clientX + "px";
            tooltip.style.top = (e.clientY - 50) + "px";
        })
        input_group.addEventListener("mouseout", function (e) {
            tooltip.classList.remove("visible");
            tooltip.classList.add("hidden");
        })
    }
})()*/

var MULTI_LINE = $MULTI_LINE;

var textareas = document.getElementsByClassName("input_textarea")
for (let i = 0; i < textareas.length; i++) {
    var txt = textareas[i];
    //Update the height on load
    updateHeight(txt);
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
    element.style.height = "auto";
    if (!element.value || MULTI_LINE) {
        element.style.height = "0px";
    }
    element.style.height = element.scrollHeight + "px";
}

function appResizeListener(e) {
    if (textareas[0].value == "") {
        textareas[0].style.height = "22px";
    }
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

// Listen for the resize event
window.addEventListener("resize", appResizeListener);