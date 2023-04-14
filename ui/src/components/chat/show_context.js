var menus = document.getElementsByClassName("context-menu")
for (var i = 0; i < menus.length; i++) {
  menus.item(i).classList.add("hidden")
}
// Select the current one
var context_menu = document.getElementById("UUID-context-menu")
context_menu.classList.remove("hidden")
var { width, height } = context_menu.getBoundingClientRect()
let offsetX = $PAGE_X
let offsetY = $PAGE_Y
let screenWidth = window.innerWidth || document.documentElement.clientWidth
let screenHeight = window.innerHeight || document.documentElement.clientHeight
let overFlowY = screenHeight < height + offsetY
let overFlowX = screenWidth < width + offsetX
context_menu.style.top = `${overFlowY ? offsetY - height : offsetY}px`
context_menu.style.left = `${overFlowX ? offsetX - width : offsetX}px`