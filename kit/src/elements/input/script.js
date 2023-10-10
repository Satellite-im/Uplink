var input_element = document.getElementById("$UUID");
if (input_element == null) {
    console.log("error: could not find input_element to focus on");
} else {
    input_element.focus();
    if (input_element.classList.contains("select")) {
        input_element.select();
        input_element.classList.remove("select")
    }
}
