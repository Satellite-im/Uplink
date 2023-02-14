interact(".resize-horiz-right")
  .resizable({
    edges: { left: false, right: true, bottom: false, top: false },

    listeners: {
      move(event) {
        var target = event.target
        var x,
          y = 0
        // update the element's style
        target.style.width = event.rect.width + "px"

        target.style.transform = "translate(" + x + "px," + y + "px)"
      },
    },
  })
  .on("resizestart", function (event) {
    var target = event.target
    target.classList.add("resizing")
  })
  .on("resizeend", function (event) {
    var target = event.target
    target.classList.remove("resizing")
  })
