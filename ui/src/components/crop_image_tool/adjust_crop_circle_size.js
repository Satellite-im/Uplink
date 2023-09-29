var imgElement = document.getElementById('image-preview-modal-file-embed');
var cropCircle = document.getElementById('crop-box');
var image_crop_box_container = document.getElementById('image-crop-box-container');

function adjustCropCircleSize() {
    var imageWidth = imgElement.clientWidth;
    var imageHeight = imgElement.clientHeight;

    var minDimension = Math.min(imageWidth, imageHeight);
    cropCircle.style.width = minDimension + 'px';
    cropCircle.style.height = minDimension + 'px';
    image_crop_box_container.style.width = minDimension + 2 + 'px';
    image_crop_box_container.style.height = minDimension + 2 + 'px';
}

window.addEventListener('resize', adjustCropCircleSize);

adjustCropCircleSize();