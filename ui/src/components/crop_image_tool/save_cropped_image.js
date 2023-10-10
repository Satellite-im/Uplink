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

const imageLeftPosition = image.style.left ? parseFloat(image.style.left) : 0;
const imageTopPosition = image.style.top ? parseFloat(image.style.top) : 0;

const cropX = Math.max(Math.abs(((naturalWidth - scaleX * width) / 2) - (scaleX * imageLeftPosition)), 0);
const cropY = Math.max(Math.abs(((naturalHeight - scaleY * height) / 2) - (scaleY * imageTopPosition)), 0);

ctx.drawImage(image, cropX, cropY, scaleX * width, scaleY * height, 0, 0, width, height);

const base64Canvas = canvas.toDataURL("image/png").split(';base64,')[1];

return base64Canvas;