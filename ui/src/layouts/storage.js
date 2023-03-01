var filesLayout = document.getElementById('files-layout')

var IS_DRAGGING = $IS_DRAGGING

var overlayElement = document.getElementById('overlay-element')

if (IS_DRAGGING) {
  filesLayout.classList.add('hover-effect')
  overlayElement.style.display = 'block'
} else {
  filesLayout.classList.remove('hover-effect')
  overlayElement.style.display = 'none'
}