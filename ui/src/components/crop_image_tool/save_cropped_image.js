var imgElement = document.getElementById('image-preview-modal-file-embed');
var cropBox = document.getElementById('crop-box');

var canvas = document.createElement('canvas');
var ctx = canvas.getContext('2d');

var cropRect = cropBox.getBoundingClientRect();
var imgRect = imgElement.getBoundingClientRect();

canvas.width = cropRect.width;
canvas.height = cropRect.height;

var offsetX = cropRect.left - imgRect.left;
var offsetY = cropRect.top - imgRect.top;

ctx.drawImage(imgElement, offsetX, offsetY, cropRect.width, cropRect.height, 0, 0, cropRect.width, cropRect.height);

const base64Canvas = canvas.toDataURL("image/png").split(';base64,')[1];


return base64Canvas;

