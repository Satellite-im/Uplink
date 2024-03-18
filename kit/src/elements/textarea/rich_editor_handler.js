/**
 * Create a new rich editor using js
 */

let text = document.getElementById('$EDITOR_ID')
var keys = [{
    key: "ArrowUp", run: () => {
        if (text.classList.contains("up-down-disabled")) {
            text.dispatchEvent(new KeyboardEvent('keydown', { 'key': 'ArrowUp' }))
            dioxus.send(`{\"KeyPress\":\"ArrowUp\"}`)
            return true;
        }
    }
},
{
    key: "ArrowDown", run: () => {
        if (text.classList.contains("up-down-disabled")) {
            text.dispatchEvent(new KeyboardEvent('keydown', { 'key': 'ArrowDown' }))
            dioxus.send(`{\"KeyPress\":\"ArrowDown\"}`)
            return true;
        }
    }
}].concat(MarkdownEditor.ChatEditorKeys(() => dioxus.send(`\"Submit\"`)))

function forwardEvent(e) {
    newEvent = new e.constructor(e.type, e)
    text.dispatchEvent(newEvent)
    return newEvent.defaultPrevented
}

function forwardEventDown(e) {
    if (e.key == 'Tab') {
        e.preventDefault();
        newEvent = new e.constructor(e.type, e)
        newEvent.preventDefault()
        text.dispatchEvent(newEvent)
        return true
    }
    newEvent = new e.constructor(e.type, e)
    text.dispatchEvent(newEvent)
    return newEvent.defaultPrevented
}

var editor = new MarkdownEditor(
    document.getElementById('$EDITOR_ID'), {
    keys: keys,
    listeners: {
        //Forward key events to underlying text area
        "keydown": forwardEventDown,
        "keyup": forwardEvent,
        "keypress": forwardEvent,
        "onblue": (e) => {
            new_event = new e.constructor(e.type, e)
            text.dispatchEvent(new_event)
        }
    },
    editable: !text.disabled,
    highlightmap: MarkdownEditor.PrismMap,
    only_autolink: true
});

editor.value('$INIT');

if ($AUTOFOCUS) {
    forceClickOnResizeArea();
    console.log("inside AUTOFOCUS");
    addEventListener("focus", () => { editor.codemirror.focus() });
}

editor.registerListener("input", ({ _element, _codemirror, value }) => {
    // Sync value to uplink
    dioxus.send(`{\"Input\":\"${value}\"}`)
});

editor.registerListener("selection", ({ _element, _codemirror, selection }) => {
    // Sync cursor to uplink
    dioxus.send(`{\"Cursor\":${selection.main.to}}`)
});

function forceClickOnResizeArea() {
    // Create a new event.
    const event = new Event('resize');
    console.log("inside funciton");
    // Dispatch the event on the window object.
    window.dispatchEvent(event);
  }