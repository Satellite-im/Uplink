interact(".resize-vert-top").resizable({
  edges: { left: false, right: false, bottom: false, top: true },

  listeners: {
    move(event) {
      var target = event.target
      var x,
        y = 0

      // update the element's style
      target.style.width = event.rect.width + "px"
      target.style.height = event.rect.height + "px"

      // translate when resizing from top edge
      y += event.deltaRect.top

      target.style.transform = "translate(" + x + "px," + y + "px)"
    },
  },
})
