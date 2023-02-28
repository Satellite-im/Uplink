var filesLayout = document.getElementById('files-layout')

var IS_DRAGGING = $IS_DRAGGING

if (IS_DRAGGING) {
  filesLayout.classList.add('hover-effect')
} else {
  filesLayout.classList.remove('hover-effect')
}