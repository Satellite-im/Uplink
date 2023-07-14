var charCounter = document.getElementById('$UUID-char-counter')

document.getElementById('$UUID').onkeyup = function() {
    document.getElementById('$UUID-char-counter').innerText = this.value.length + "/$MAX_LENGTH";
};