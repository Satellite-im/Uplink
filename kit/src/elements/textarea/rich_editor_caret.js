// Unused, delete in future
function setCursorPosition(parent, range, stat) {
  if (stat.done) return range;
  if (parent.childNodes.length == 0) {
    if (parent.textContent.length >= stat.pos) {
      range.setStart(parent, stat.pos);
      stat.done = true;
    } else {
      stat.pos = stat.pos - parent.textContent.length;
    }
  } else {
    for (let i = 0; i < parent.childNodes.length && !stat.done; i++) {
      currentNode = parent.childNodes[i];
      setCursorPosition(currentNode, range, stat);
    }
  }
  return range;
}

var el = document.getElementById("$ID");
var sel = window.getSelection();
var pos = "$CARET";
console.log("car ", pos);
sel.removeAllRanges();
var range = setCursorPosition(el, document.createRange(), {
  pos: pos,
  done: false,
});
range.collapse(true);
sel.addRange(range);