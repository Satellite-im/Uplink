let page = document.getElementById("enter-seed-words-layout");
let inputs = page.getElementsByTagName("input");
for (let input of inputs) {
    input.addEventListener("paste", event => {
        event.preventDefault();
        let paste = (event.clipboardData || window.clipboardData).getData("text");
        dioxus.send(paste)
    })
}