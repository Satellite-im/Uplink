var imgElement = document.getElementById('image-preview-modal-file-embed');

var imgStyle = window.getComputedStyle(imgElement);

var maxWidth = imgStyle.getPropertyValue('max-width');
var maxHeight = imgStyle.getPropertyValue('max-height');

var imageWidth = imgElement.width;
var imageHeight = imgElement.height;

return {"width": imageWidth, "height": imageHeight};