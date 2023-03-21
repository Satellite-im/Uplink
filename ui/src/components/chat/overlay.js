var chatLayout = document.getElementById('compose')

var IS_DRAGGING = $IS_DRAGGING

var overlayElement = document.getElementById('overlay-element')

if (IS_DRAGGING) {
  chatLayout.classList.add('hover-effect')
  overlayElement.style.display = 'block'
} else {
  chatLayout.classList.remove('hover-effect')
  overlayElement.style.display = 'none'
}