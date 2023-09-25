// Get the image element by its ID
var imgElement = document.getElementById('image-preview-modal-file-embed');

// Get the computed style of the image element
var imgStyle = window.getComputedStyle(imgElement);

// Get the maximum width and maximum height
var maxWidth = imgStyle.getPropertyValue('max-width');
var maxHeight = imgStyle.getPropertyValue('max-height');

var imageWidth = imgElement.width;
var imageHeight = imgElement.height;

return {"width": imageWidth, "height": imageHeight};