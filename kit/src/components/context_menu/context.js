let click = (toggle) => function (ev) {
  ev.stopPropagation()
  ev.preventDefault()
  // Hide any open context menus
  const menus = document.getElementsByClassName("context-menu")
  // Select the current one
  const context_menu = document.getElementById("UUID-context-menu")
  let hidden = context_menu.classList.contains("hidden");
  for (var i = 0; i < menus.length; i++) {
    menus.item(i).classList.add("hidden")
  }
  if (toggle && !hidden) {
    context_menu.classList.add("hidden")
    return
  } else {
    context_menu.classList.remove("hidden")
  }
  const { width, height } = context_menu.getBoundingClientRect()
  let offsetX = ev.pageX
  let offsetY = ev.pageY
  let screenWidth = ev.view.innerWidth
  let screenHeight = ev.view.innerHeight
  let overFlowY = screenHeight < height + offsetY
  let overFlowX = screenWidth < width + offsetX
  let topY = Math.max(5, overFlowY ? offsetY - height : offsetY)
  let minX = 5
  let compose = document.getElementsByClassName("slimbar")[0]
  if (compose) {
    minX = compose.getBoundingClientRect().right
  }
  let topX = Math.max(minX, overFlowX ? offsetX - width : offsetX)
  context_menu.style.top = `${topY}px`
  context_menu.style.left = `${topX}px`
  return false
}

document.getElementById("UUID").addEventListener(
  "contextmenu",
  click(false),
  false,
)

if (ON_CLICK) {
  document.getElementById("UUID").addEventListener(
    "click",
    click(true),
    false,
  )
}

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
