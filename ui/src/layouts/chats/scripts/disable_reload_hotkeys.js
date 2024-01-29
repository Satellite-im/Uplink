document.addEventListener("keydown", function(event) {
    if (event.ctrlKey && event.shiftKey && event.key === "R") {
        event.preventDefault();
    }
});