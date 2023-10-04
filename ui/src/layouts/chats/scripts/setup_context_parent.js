let x = function tmp() {
    const right_clickable = document.getElementsByClassName("has-context-handler");
    console.log("E", right_clickable);
    const prevent_default = function (ev) { ev.preventDefault(); };
    for (var i = 0; i < right_clickable.length; i++) {
        //Disable default right click actions (opening the inspect element dropdown)
        right_clickable.item(i).removeEventListener("contextmenu", prevent_default);
        right_clickable.item(i).addEventListener("contextmenu", prevent_default);
    }
};

x();
return "done";
