// Update placeholder text
var e = document.getElementById('$UUID').nextSibling.querySelector('.CodeMirror');
if (e) {
    var cm = e.CodeMirror;
    cm.setOption('placeholder', "$PLACEHOLDER");
}