document.getElementById("UUID").addEventListener(
  "contextmenu",
  function (ev) {
    ev.stopPropagation()
    ev.preventDefault()
    // Hide any open context menus
    const menus = document.getElementsByClassName("context-menu")
    for (var i = 0; i < menus.length; i++) {
      menus.item(i).classList.add("hidden")
    }
    // Select the current one
    const context_menu = document.getElementById("UUID-context-menu")
    context_menu.classList.remove("hidden")
    const { width, height } = context_menu.getBoundingClientRect()
    let offsetX = ev.pageX
    let offsetY = ev.pageY
    let screenWidth = ev.view.innerWidth
    let screenHeight = ev.view.innerHeight
    let overFlowY = screenHeight < height + offsetY
    let overFlowX = screenWidth < width + offsetX
    context_menu.style.top = `${overFlowY ? offsetY - height : offsetY}px`
    context_menu.style.left = `${overFlowX ? offsetX - width : offsetX}px`
    return false
  },
  false,
)

//Hide the context menu only if context items are clicked
document.getElementById("UUID-context-menu").addEventListener("click", (e) => {
  const context_menu = document.getElementById("UUID-context-menu")
  const ctx_items = context_menu.getElementsByClassName("context-item");
  for (const i of ctx_items) {
    const rect = i.getBoundingClientRect()
    if (e.clientX >= rect.left && e.clientX <= rect.right && e.clientY >= rect.top && e.clientY <= rect.bottom) {
      context_menu.classList.add("hidden")
      break;
    }
  }
})

//Hides the context menu if clicked outside
document.addEventListener("click", (e) => {
  const context_menu = document.getElementById("UUID-context-menu")
  if (context_menu != null) {
    const rect = context_menu.getBoundingClientRect()
    if (e.clientX < rect.left || e.clientX > rect.right || e.clientY < rect.top || e.clientY > rect.bottom)
      context_menu.classList.add("hidden")
  }
})
