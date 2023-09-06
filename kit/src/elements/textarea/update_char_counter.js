var charCounter = document.getElementById('$UUID-char-counter')
function countGraphemeClusters(input) {
  return Array.from(input).length;
}
// Run first too
var count = countGraphemeClusters(document.getElementById('$UUID').value)
charCounter.innerText = count;

document.getElementById('$UUID').onkeyup = function() {
    const charCount = countGraphemeClusters(this.value);
    charCounter.innerText = charCount;
};