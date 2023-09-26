var imgElement = document.getElementById('image-preview-modal-file-embed');
var cropCircle = document.getElementById('crop-box');

function adjustCropCircleSize() {
    var imageWidth = imgElement.clientWidth;
    var imageHeight = imgElement.clientHeight;

    var minDimension = Math.min(imageWidth, imageHeight);
    cropCircle.style.width = minDimension + 'px';
    cropCircle.style.height = minDimension + 'px';
}

window.addEventListener('resize', adjustCropCircleSize);

adjustCropCircleSize();