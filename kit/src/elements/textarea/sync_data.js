function countGraphemeClusters(input) {
  return Array.from(input).length;
}

var text = "$TEXT"
var e = document.getElementById('$UUID')
var update = "$UPDATE";
if (update === "true" && e.markdownEditor) {
  // Only update if text differs
  if (e.markdownEditor.value() !== text) {
    e.markdownEditor.value(text);
  }
  e.markdownEditor.updatePlaceholder("$PLACEHOLDER")
  e.markdownEditor.setEditable(!$DISABLED)
}

var counter = document.getElementById('$UUID-char-counter');
if (counter) {
  var count = countGraphemeClusters(text)
  counter.innerText = count;
}

