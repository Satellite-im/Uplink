var charCounter = document.getElementById('$UUID-char-counter')

function countGraphemeClusters(input) {
    return Array.from(input).length;
  }

document.getElementById('$UUID').onkeyup = function() {
    const charCount = countGraphemeClusters(this.value);
    charCounter.innerText = charCount;
};