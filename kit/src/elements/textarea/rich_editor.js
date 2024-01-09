// Unused, delete in future
var txt = document.getElementById("$UUID")
if (!txt.rich_event_listener) {
    txt.addEventListener("input", inputListener);
    document.addEventListener("selectionchange", handleSelectionChangeEvent);
    txt.addEventListener("paste", handlePaste);
    txt.rich_event_listener = true;
}

function inputListener(e) {
    //Cache caret pos
    var sel = window.getSelection();
    var node = sel.focusNode;
    var offset = sel.focusOffset;
    var pos = getCaretPosition(this, node, offset, { pos: 0, done: false });
    if (offset === 0 && pos.pos != 0) pos.pos += 0.5;
    console.log(getCurrentCursorPosition(txt));
    dioxus.send(`${pos.pos},${this.innerText}`)
}

async function update_markdown(e) {

}

function handleSelectionChangeEvent(e) {
    //console.log(e)
    var sel = window.getSelection();
    var node = sel.focusNode;
    var offset = sel.focusOffset;
    var pos = getCaretPosition(txt, node, offset, { pos: 0, done: false });
    //if (offset === 0) pos.pos += 0.5;
    console.log(getCurrentCursorPosition(txt));
}

function handlePaste(e) {
    //console.log(e)
}

function getCaretPosition(parent, node, offset, stat) {
    if (stat.done) return stat;

    let currentNode = null;
    if (parent.childNodes.length == 0) {
        stat.pos += parent.textContent.length;
    } else {
        for (let i = 0; i < parent.childNodes.length && !stat.done; i++) {
            currentNode = parent.childNodes[i];
            if (currentNode === node) {
                stat.pos += offset;
                stat.done = true;
                return stat;
            } else getCaretPosition(currentNode, node, offset, stat);
        }
    }
    return stat;
}

function getCurrentCursorPosition(parent) {
    var selection = window.getSelection(),
        charCount = -1,
        node;

    let parentId = parent.id;

    if (selection.focusNode) {
            node = selection.focusNode; 
            charCount = selection.focusOffset;

            while (node) {
                if (node.id === parentId) {
                    break;
                }

                if (node.previousSibling) {
                    node = node.previousSibling;
                    charCount += node.textContent.length;
                } else {
                     node = node.parentNode;
                     if (node === null) {
                         break
                     }
                }
      }
   }

    return charCount;
};