const img = document.getElementById('image-preview-modal-file-embed');
let offsetX = 0, offsetY = 0, isDragging = false;

img.addEventListener('mousedown', function(e) {
    isDragging = true;
    offsetX = e.clientX - parseInt(img.style.left || 0);
    offsetY = e.clientY - parseInt(img.style.top || 0);
});

document.addEventListener('mousemove', function(e) {
    if (isDragging) {
        const left = e.clientX - offsetX;
        const top = e.clientY - offsetY;
        
        img.style.left = `${left}px`;
        img.style.top = `${top}px`;
    }
});

document.addEventListener('mouseup', function() {
    isDragging = false;
});

// Para prevenir o arrasto padrão da imagem.
img.ondragstart = function() {
    return false;
};
