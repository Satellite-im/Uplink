;(() => {
  class Box {
    constructor() {
      // Add a flag to indicate whether an animation frame is running
      this.animationFrameRunning = false

      // Add a scale property to store the current scale of the element
      this.scale = 1

      this.box = document.querySelector(".popout-player")
      this.handleMouseDown = this.handleMouseDown.bind(this)
      this.handleMouseUp = this.handleMouseUp.bind(this)
      this.handleMouseMove = this.handleMouseMove.bind(this)
      this.handleDoubleClick = this.handleDoubleClick.bind(this)

      // Bind the double click event to the handleDoubleClick method
      this.box.addEventListener("dblclick", this.handleDoubleClick)
    }

    handleDoubleClick() {
      if (this.scale == 1) {
        this.scale += 0.25
      } else {
        this.scale -= 0.25
      }

      // Update the transform property of the element to apply the scale
      this.box.style.transform = `scale(${this.scale})`
    }

    handleMouseDown(e) {
      // Return early if an animation frame is running
      if (this.animationFrameRunning) {
        return
      }

      this.box.classList.add("dragging")
      this.box.style.cursor = "move"
      this.box.addEventListener("mouseup", this.handleMouseUp)
      document.body.addEventListener("mousemove", this.handleMouseMove)
      document.body.addEventListener("mouseleave", this.handleMouseUp)

      // Update the position of the element to take into account the current scale
      const boxRect = this.box.getBoundingClientRect()
      this.startX = boxRect.left - e.clientX * this.scale
      this.startY = boxRect.top - e.clientY * this.scale
    }

    handleMouseUp() {
      // Return early if an animation frame is running
      if (this.animationFrameRunning) {
        return
      }

      this.box.classList.remove("dragging")
      this.box.style.cursor = "default"
      document.body.removeEventListener("mousemove", this.handleMouseMove)
      document.body.removeEventListener("mouseleave", this.handleMouseUp)

      // Snap the element to the nearest edge of the screen if it is within 200 pixels of the edge
      const boxRect = this.box.getBoundingClientRect()
      const left = boxRect.left
      const right = window.innerWidth - boxRect.right
      const top = boxRect.top
      const bottom = window.innerHeight - boxRect.bottom

      if (left < 100 || right < 100 || top < 100 || bottom < 100) {
        // Set the flag to indicate that an animation frame is running
        this.animationFrameRunning = true

        // Animate the element moving to the nearest edge
        let start
        const step = (timestamp) => {
          if (!start) start = timestamp
          const progress = timestamp - start
          const easing = (t) =>
            t < 0.5 ? 4 * t * t * t : (t - 1) * (2 * t - 2) * (2 * t - 2) + 1
          const scale = easing(progress / 120)
          if (left < right && left < top && left < bottom) {
            this.box.style.left = `${left * (1 - scale)}px`
          } else if (right < left && right < top && right < bottom) {
            this.box.style.left = `${boxRect.left + right * scale}px`
          }
          if (top < left && top < right && top < bottom) {
            this.box.style.top = `${top * (1 - scale)}px`
          } else if (bottom < left && bottom < right && bottom < top) {
            this.box.style.top = `${boxRect.top + bottom * scale}px`
          }
          if (progress < 120) {
            requestAnimationFrame(step)
          }
        }
        requestAnimationFrame(step)
        this.animationFrameRunning = false
      }
    }

    handleMouseMove(e) {
      const boxRect = this.box.getBoundingClientRect()
      let newTop = boxRect.top + e.movementY
      let newLeft = boxRect.left + e.movementX

      // Ensure that the box stays within the boundaries of the screen
      newTop = Math.max(
        0,
        Math.min(newTop, window.innerHeight - boxRect.height),
      )
      newLeft = Math.max(
        0,
        Math.min(newLeft, window.innerWidth - boxRect.width),
      )

      // Update the position of the element to take into account the current scale
      this.box.style.left = `${this.startX + e.clientX * this.scale}px`
      this.box.style.top = `${this.startY + e.clientY * this.scale}px`
    }

    init() {
      this.box.addEventListener("mousedown", this.handleMouseDown)
    }
  }

  const box = new Box()
  box.init()
})()
