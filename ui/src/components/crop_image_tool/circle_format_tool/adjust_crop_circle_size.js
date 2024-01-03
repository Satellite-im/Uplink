var imgElement = document.getElementById('image-preview-modal-file-embed');
var cropCircle = document.getElementById('crop-box');
var shadowImgMask = document.getElementById('shadow-img-mask');
var image_crop_box_container = document.getElementById('image-crop-box-container');
var img_parent_div = document.getElementById('img-parent-div');

function adjustCropCircleSize() {
    var imageWidth = imgElement.clientWidth;
    var imageHeight = imgElement.clientHeight;

    var minDimension = Math.min(imageWidth, imageHeight);

    var cropCircleDiameter = (minDimension - 24);

    cropCircle.style.width = cropCircleDiameter + 'px';
    cropCircle.style.height = cropCircleDiameter + 'px';

    shadowImgMask.style.width = imageWidth + 'px';
    shadowImgMask.style.height = imageHeight + 'px';

    img_parent_div.style.width = imageWidth + 'px';
    img_parent_div.style.height = imageHeight + 'px';

    var hypotenuse = Math.sqrt(imageWidth ** 2 + imageHeight ** 2);
    var correctPercentage = (cropCircleDiameter / hypotenuse) * 100;

    // Setting values for ::before
    shadowImgMask.style.setProperty('--shadow-img-mask-before-top', '-1%');
    shadowImgMask.style.setProperty('--shadow-img-mask-before-left', '-1%');
    shadowImgMask.style.setProperty('--shadow-img-mask-before-right', '-1%');
    shadowImgMask.style.setProperty('--shadow-img-mask-before-bottom', '-1%');
    shadowImgMask.style.setProperty('--shadow-img-mask-before-background', 'radial-gradient(circle at center, transparent ' + `${correctPercentage}` + '%, black 50%)');
}

window.addEventListener('resize', adjustCropCircleSize);

adjustCropCircleSize();