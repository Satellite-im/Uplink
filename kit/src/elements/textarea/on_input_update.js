function countGraphemeClusters(input) {
  return Array.from(input).length;
}
// Update char counter if exist
var counter = document.getElementById("$UUID-chatbar-char-counter");
if (counter) {
  counter.innerText = countGraphemeClusters("$TEXT");
}

// Sync scroll value if exist
var styled = document.getElementById(`$UUID-styled-text`);
if (styled) {
  styled.scrollTop = document.getElementById("$UUID").scrollTop;
  Prism.highlightAllUnder(styled);
}