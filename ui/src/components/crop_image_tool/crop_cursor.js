const cursor = document.getElementById('crop-cursor');
let isDragging = false;

// Function to set cursor position
function setCursorPosition(x, y) {
    cursor.style.left = `${x - cursor.offsetWidth / 2}px`;
    cursor.style.top = `${y - cursor.offsetHeight / 2}px`;
}

// Function to resize cursor
function setCursorSize(size) {
    cursor.style.width = `${size}px`;
    cursor.style.height = `${size}px`;
    cursor.style.borderRadius = `${size / 2}px`;
}

// Event listeners for mouse actions
cursor.addEventListener('mousedown', () => {
    isDragging = true;
});

document.addEventListener('mousemove', (e) => {
    if (isDragging) {
        setCursorPosition(e.clientX, e.clientY);
    }
});

document.addEventListener('mouseup', () => {
    isDragging = false;
});

// Adjust cursor size and position initially
setCursorPosition(window.innerWidth / 2, window.innerHeight / 2);
setCursorSize(100);