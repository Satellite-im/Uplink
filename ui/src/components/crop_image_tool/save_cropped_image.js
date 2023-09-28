const image = document.getElementById('image-preview-modal-file-embed');
const cropBox = document.getElementById('crop-box');
const { width, height } = cropBox.getBoundingClientRect();
const { naturalWidth, naturalHeight } = image;

const canvas = document.createElement('canvas');
canvas.width = width;
canvas.height = height;
const ctx = canvas.getContext('2d');

const scale = $IMAGE_SCALE;

const scaleX = naturalWidth / (image.width / scale);
const scaleY = naturalHeight / (image.height / scale);

const cropX = (naturalWidth - scaleX * width) / 2;
const cropY = (naturalHeight - scaleY * height) / 2;

ctx.drawImage(image, cropX, cropY, scaleX * width, scaleY * height, 0, 0, width, height);

const base64Canvas = canvas.toDataURL("image/png").split(';base64,')[1];

return base64Canvas;

