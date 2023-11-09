let xPadding = 30
let yPadding = 10
if ($SELF) {
  xPadding *= -1;
}

var menus = document.getElementsByClassName("context-menu")
for (var i = 0; i < menus.length; i++) {
  menus.item(i).classList.add("hidden")
}
// Select the current one
var context_menu = document.getElementById("UUID-context-menu")
context_menu.classList.remove("hidden")
var { width, height } = context_menu.getBoundingClientRect()
// The offset coords using the clicked position as absolute screen coords
let offsetX = $PAGE_X + xPadding
let offsetY = $PAGE_Y - yPadding + height
// Sizes of the whole app screen
let screenWidth = window.innerWidth || document.documentElement.clientWidth
let screenHeight = window.innerHeight || document.documentElement.clientHeight

let overFlowY = offsetY + yPadding > screenHeight
context_menu.style = ""
context_menu.style.position = "absolute"
context_menu.style.bottom = `${overFlowY ? yPadding : screenHeight - offsetY}px`
if ($SELF) {
  context_menu.style.right = `${screenWidth - offsetX}px`
} else {
  // The context menu should be relative to the parents dimensions
  let parentRect = context_menu.parentElement.parentElement.getBoundingClientRect()
  let parentOffsetX = parentRect.left
  context_menu.style.left = `${offsetX - parentOffsetX}px`
}