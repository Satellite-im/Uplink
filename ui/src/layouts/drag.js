var elementId = 'no_element';
var element = null;
var elementsChecked = 0;
var maxElements = 100;

var x = $OFFSET_X;
var y = $OFFSET_Y;

var element = document.elementFromPoint(x, y);

while (element && elementsChecked < maxElements) {
    if (element.tagName === 'DIV' && element.getAttribute('aria-label') === 'favorite-chat-item-on-slimbar') {
        elementId = element.id;
        break;
    }

    elementsChecked++;

    var children = element.children;
    if (children.length > 0) {
        element = children[0];
    } else {
        while (!element.nextElementSibling && element.parentElement) {
            element = element.parentElement;
        }
        element = element.nextElementSibling;
    }
}

return element.id;
