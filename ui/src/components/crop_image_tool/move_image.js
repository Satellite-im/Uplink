const img = document.getElementById('image-preview-modal-file-embed');
const container = img.parentElement;
let offsetX = 0, offsetY = 0, isDragging = false;

container.addEventListener('mousedown', function(e) {
    isDragging = true;
    offsetX = e.clientX - parseInt(img.style.left || 0);
    offsetY = e.clientY - parseInt(img.style.top || 0);
});

document.addEventListener('mousemove', function(e) {
    if (isDragging) {
        let left = e.clientX - offsetX;
        let top = e.clientY - offsetY;
        
        // // Garante que a imagem não saia da div
        // if (left > 0) left = 0;
        // if (top > 0) top = 0;
        // if (left < container.clientWidth - img.clientWidth) left = container.clientWidth - img.clientWidth;
        // if (top < container.clientHeight - img.clientHeight) top = container.clientHeight - img.clientHeight;
        
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
