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

document.addEventListener("click", (_) => {
  const context_menu = document.getElementById("UUID-context-menu")
  context_menu.classList.add("hidden")
})
