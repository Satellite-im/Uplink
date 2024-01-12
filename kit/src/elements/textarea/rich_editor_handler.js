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

function forwardevent(e) {
    newEvent = new e.constructor(e.type, e)
    text.dispatchEvent(newEvent)
    return newEvent.defaultPrevented
}

var editor = new MarkdownEditor(
    document.getElementById('$EDITOR_ID'), {
    keys: keys,
    listeners: {
        //Forward key events to underlying text area
        "keydown": forwardevent,
        "keyup": forwardevent,
        "keypress": forwardevent,
        "onblue": (e) => {
            new_event = new e.constructor(e.type, e)
            text.dispatchEvent(new_event)
        }
    },
    editable: !text.disabled,
    highlightmap: MarkdownEditor.PrismMap
});

editor.value('$INIT');

editor.registerListener("input", ({ _element, _codemirror, value }) => {
    // Sync value to uplink
    dioxus.send(`{\"Input\":\"${value.replaceAll("\"", '\\"').replaceAll("\n", '\\n')}\"}`)
});

editor.registerListener("selection", ({ _element, _codemirror, selection }) => {
    // Sync cursor to uplink
    dioxus.send(`{\"Cursor\":${selection.main.to}}`)
});