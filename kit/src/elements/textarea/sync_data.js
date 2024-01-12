function countGraphemeClusters(input) {
  return Array.from(input).length;
}

var text = "$TEXT"
var e = document.getElementById('$UUID')
var update = "$UPDATE";
if (e.markdownEditor) {
  // Only update if text differs
  if (update === "true" && e.markdownEditor.value() !== text) {
    e.markdownEditor.value(text);
  }
  let placeholder = "$PLACEHOLDER"
  if (placeholder !== "$"+"PLACEHOLDER")  
    e.markdownEditor.updatePlaceholder(placeholder)
  e.markdownEditor.setEditable("$DISABLED" !== "true")
}

var counter = document.getElementById('$UUID-char-counter');
if (counter) {
  var count = countGraphemeClusters(text)
  counter.innerText = count;
}

