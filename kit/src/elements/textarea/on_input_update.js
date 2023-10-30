function countGraphemeClusters(input) {
  return Array.from(input).length;
}
var id = '$UUID'
var text = "$TEXT"

// Update char counter if exist
var counter = document.getElementById(`${id}-char-counter`);
if (counter) {
  counter.innerText = countGraphemeClusters(text);
}

// Sync scroll value if exist
var styled = document.getElementById(`${id}-styled-text`);
if (styled) {
  styled.scrollTop = document.getElementById(id).scrollTop;
  Prism.highlightAllUnder(styled);
}