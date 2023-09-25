const right_clickable = document.getElementsByClassName("has-context-handler")
console.log("E", right_clickable)
for (var i = 0; i < right_clickable.length; i++) {
    //Disable default right click actions (opening the inspect element dropdown)
    right_clickable.item(i).addEventListener("contextmenu",
    function (ev) {
    ev.preventDefault()
    })
}