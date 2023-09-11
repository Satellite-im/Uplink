function countGraphemeClusters(input) {
  return Array.from(input).length;
}

var text = $TEXT

var count = countGraphemeClusters(text)
document.getElementById('$UUID-char-counter').innerText = count;