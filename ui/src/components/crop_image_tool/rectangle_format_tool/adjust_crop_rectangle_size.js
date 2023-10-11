var imgElement = document.getElementById('image-preview-modal-file-embed');
var cropRectangle = document.getElementById('crop-box');
var shadowImgMask = document.getElementById('shadow-img-mask');
var image_crop_box_container = document.getElementById('image-crop-box-container');
var img_parent_div = document.getElementById('img-parent-div');
const pixelsToLetRectangleInsideImage = 6;

function adjustCropCircleSize() {
    var imageWidth = imgElement.clientWidth;
    var imageHeight = imgElement.clientHeight;

    var cropRectangleWidth = imageWidth;

    cropRectangle.style.width = cropRectangleWidth - pixelsToLetRectangleInsideImage + 'px';
    cropRectangle.style.height = '100px';

    shadowImgMask.style.width = imageWidth + 'px';
    shadowImgMask.style.height = imageHeight + 'px';

    img_parent_div.style.width = imageWidth + 'px';
    img_parent_div.style.height = imageHeight + 'px';

    var hypotenuse = Math.sqrt(imageWidth ** 2 + imageHeight ** 2);
    var correctPercentage = (cropRectangleWidth / hypotenuse) * 100;

    const gradient = `
        linear-gradient(to top, black, black ${correctPercentage}%, transparent ${correctPercentage}%, transparent),
        linear-gradient(to bottom, black, black ${correctPercentage}%, transparent ${correctPercentage}%, transparent),
        linear-gradient(to left, black, black ${correctPercentage}%, transparent ${correctPercentage}%, transparent),
        linear-gradient(to right, black, black ${correctPercentage}%, transparent ${correctPercentage}%, transparent)
    `;

    // Setting values for ::before
    shadowImgMask.style.setProperty('--shadow-img-mask-before-top', '-1%');
    shadowImgMask.style.setProperty('--shadow-img-mask-before-left', '-1%');
    shadowImgMask.style.setProperty('--shadow-img-mask-before-right', '-1%');
    shadowImgMask.style.setProperty('--shadow-img-mask-before-bottom', '-1%');
    shadowImgMask.style.setProperty('--shadow-img-mask-before-background', gradient);
}


window.addEventListener('resize', adjustCropCircleSize);

adjustCropCircleSize();