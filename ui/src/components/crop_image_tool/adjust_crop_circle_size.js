var imgElement = document.getElementById('image-preview-modal-file-embed');
var cropCircle = document.getElementById('crop-box');
var cropCircle2 = document.getElementById('crop-box2');
var image_crop_box_container = document.getElementById('image-crop-box-container');
var firstRender = '$FIRST_RENDER';

function adjustCropCircleSize() {
    var imageWidth = imgElement.clientWidth;
    var imageHeight = imgElement.clientHeight;

    var minDimension = Math.min(imageWidth, imageHeight);

    var cropCircleDiameter = (minDimension - 24);

    cropCircle.style.width = cropCircleDiameter + 'px';
    cropCircle.style.height = cropCircleDiameter + 'px';

    cropCircle2.style.width = imageWidth + 'px';
    cropCircle2.style.height = imageHeight + 'px';

    var hypotenuse = Math.sqrt(imageWidth ** 2 + imageHeight ** 2);
    var correctPercentage = (cropCircleDiameter / hypotenuse) * 100;

    // Setting values for ::before
    cropCircle2.style.setProperty('--crop-box-before-top', '-1%');
    cropCircle2.style.setProperty('--crop-box-before-left', '-1%');
    cropCircle2.style.setProperty('--crop-box-before-right', '-1%');
    cropCircle2.style.setProperty('--crop-box-before-bottom', '-1%');
    cropCircle2.style.setProperty('--crop-box-before-background', 'radial-gradient(circle at center, transparent ' + `${correctPercentage}` + '%, black 50%)');
}


if (firstRender) {
    window.addEventListener('resize', adjustCropCircleSize);
}

adjustCropCircleSize();