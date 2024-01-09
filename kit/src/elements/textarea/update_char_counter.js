function countGraphemeClusters(input) {
  return Array.from(input).length;
}

var text = "$TEXT"
var e = document.getElementById('$UUID').nextSibling.querySelector('.CodeMirror');
if (editor) {
  var cm = e.CodeMirror;
  // Only update if text differs
  if (cm.getValue() !== text) {
    cm.setValue(text);
  }
}

var count = countGraphemeClusters(text)
document.getElementById('$UUID-char-counter').innerText = count;

