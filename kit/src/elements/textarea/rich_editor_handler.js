// Init EasyMDE
var easyMDE = new EasyMDE({
    element: document.getElementById('$EDITOR_ID'),
    toolbar: false,
    inputStyle: "contenteditable",
    status: false,
    scrollbarStyle: "null",
    minHeight: "0",
    theme: null,
    styleSelectedText: false,
    renderingConfig: {
        codeSyntaxHighlighting: true
    }
});

easyMDE.value('$INIT');

easyMDE.codemirror.on("change", () => {
    // Sync value to uplink
    dioxus.send(`{\"Input\":\"${easyMDE.value().replaceAll("\n", '\\n')}\"}`)
});

easyMDE.codemirror.on("cursorActivity", () => {
    var c = easyMDE.codemirror.getCursor()
    var lines = easyMDE.value().split('\n')
    var charAt = c.ch;
    for (var i = 0; i < c.line; i++) {
        charAt += lines[i].length + 1
    }
    // Sync cursor position to uplink
    dioxus.send(`{\"Cursor\":${charAt}}`)
});