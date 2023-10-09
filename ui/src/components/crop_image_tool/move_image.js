const img = document.getElementById('image-preview-modal-file-embed');
const container = document.getElementById('image-crop-box-container');
const cropBox = document.getElementById('crop-box');
let offsetX = 0, offsetY = 0, isDragging = false;

container.addEventListener('mousedown', function(e) {
    isDragging = true;
    offsetX = e.clientX - parseInt(img.style.left || 0);
    offsetY = e.clientY - parseInt(img.style.top || 0);
});

document.addEventListener('mousemove', function(e) {
    if (isDragging) {
        var imgScale = Math.max(1, img.getBoundingClientRect().width / img.offsetWidth);


        let left = (e.clientX - offsetX);
        let top = (e.clientY - offsetY);

        const containerWidth = container.clientWidth;
        const containerHeight = container.clientHeight;
        const cropBoxWidth = cropBox.clientWidth;
        const cropBoxHeight = cropBox.clientHeight;

        var leftIsNegative = false;
        var topIsNegative = false;


        var leftIsNegative = left < 0;
        var topIsNegative = top < 0;

        left = Math.min(Math.abs(left), ((containerWidth * imgScale) - cropBoxWidth) / 2);
        top = Math.min(Math.abs(top), ((containerHeight * imgScale) - cropBoxHeight) / 2);

        if (leftIsNegative) {
            left = -left;
        }
        if (topIsNegative) {
            top = -top;
        }

        img.style.left = `${left}px`;
        img.style.top = `${top}px`;
    }
});

document.addEventListener('mouseup', function() {
    isDragging = false;
});

img.ondragstart = function() {
    return false;
};


return {"left": img.style.left, "top": img.style.top};
