const pin_click = function (e) {
    e.stopPropagation()
    var pinned = document.getElementById("pinned-messages-container")
    if (pinned != null) {
        if (pinned.classList.contains("hidden")) {
            pinned.classList.remove("hidden")
            pin_btn_wrap.getElementsByClassName("tooltip")[0].classList.add("hidden")
        } else {
            pinned.classList.add("hidden")
            pin_btn_wrap.getElementsByClassName("tooltip")[0].classList.remove("hidden")
        }
    }
}

const outside_click = function (e) {
    var pinned = document.getElementById("pinned-messages-container")
    if (pinned != null) {
        var rect = pinned.getBoundingClientRect()
        if (e.clientX < rect.left || e.clientX > rect.right || e.clientY < rect.top || e.clientY > rect.bottom) {
            pinned.classList.add("hidden")
        }
    }
}


var pin_btn_wrap = document.getElementById("pin-button")
var pin_btn = pin_btn_wrap.getElementsByClassName("btn")[0]

pin_btn.addEventListener("click", pin_click)
document.addEventListener("click", outside_click)