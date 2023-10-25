var imgElement = document.getElementById('image-preview-modal-file-embed');
var cropRectangle = document.getElementById('crop-box');
var shadowImgMask = document.getElementById('shadow-img-mask');
var image_crop_box_container = document.getElementById('image-crop-box-container');
var img_parent_div = document.getElementById('img-parent-div');
const cropRectangleHeight = 80;
const pixelsToLetRectangleInsideImage = 6;

function adjustCropCircleSize() {
    var imageWidth = imgElement.clientWidth;
    var imageHeight = imgElement.clientHeight;

    var cropRectangleWidth = imageWidth;

    cropRectangle.style.width = cropRectangleWidth - pixelsToLetRectangleInsideImage + 'px';
    cropRectangle.style.height = cropRectangleHeight + 'px';

    shadowImgMask.style.width = imageWidth + 'px';
    shadowImgMask.style.height = imageHeight + 'px';

    img_parent_div.style.width = imageWidth + 'px';
    img_parent_div.style.height = imageHeight + 'px';

    const heightOfTransparentArea = cropRectangleHeight;

    const shadowAtTop = `linear-gradient(black, black calc(50% - ${heightOfTransparentArea / 2}px), transparent calc(50% - ${heightOfTransparentArea / 2}px), transparent)`;
    const shadowAtBottom = `linear-gradient(transparent calc(50% - ${heightOfTransparentArea / 2}px), transparent calc(50% + ${heightOfTransparentArea / 2}px), black calc(50% + ${heightOfTransparentArea / 2}px), black)`;
    
    const combinedBackground = `${shadowAtTop}, ${shadowAtBottom}`;

    // Setting values for ::before
    shadowImgMask.style.setProperty('--shadow-img-mask-before-top', '-1%');
    shadowImgMask.style.setProperty('--shadow-img-mask-before-left', '-1%');
    shadowImgMask.style.setProperty('--shadow-img-mask-before-right', '-1%');
    shadowImgMask.style.setProperty('--shadow-img-mask-before-bottom', '-1%');
    shadowImgMask.style.setProperty('--shadow-img-mask-before-background', combinedBackground);
}

window.addEventListener('resize', adjustCropCircleSize);

adjustCropCircleSize();