function correctUnicodeOffset(offset, str) {
    if (offset < 1) return offset;
    return Array.from(str.substr(0, offset)).length;
}
var e = document.getElementById("$ID");
return correctUnicodeOffset(e.selectionEnd, e.value);