> webgl2 notes
- these notes are specifically for webgl2
- the objective is to figure out how to use webgl to transform a yub image into a rgb image and display it on a canvas
- the below example claims do do that but it needs modification for any other use case and to modify it, one has to know a few things about wegbl2
---

# mozilla tutorial
- https://developer.mozilla.org/en-US/docs/Web/API/WebGL_API/Tutorial
- not sure if this one should be done before or after webgl2fundamentals

# reading
- read first https://webgl2fundamentals.org/webgl/lessons/webgl-fundamentals.html
- read this second: https://webgl2fundamentals.org/webgl/lessons/webgl-how-it-works.html
- helpful visualization: https://webgl2fundamentals.org/webgl/lessons/resources/webgl-state-diagram.html
- setup script used by examples: https://webgl2fundamentals.org/webgl/resources/webgl-utils.js

# notes
- webgl primitives: https://webgl2fundamentals.org/webgl/lessons/webgl-points-lines-triangles.html
    - there's a way to tell webgl how to interpret the list of points you provide it (a vertex array). usually every 3 points draws a triangle. The behavior is determined by the first argument to gl.drawArrays and gl.drawElements
    - to draw a quadrilateral, need 6 vertices to make 2 triangles. 
- textures: https://developer.mozilla.org/en-US/docs/Web/API/WebGL_API/Tutorial/Using_textures_in_WebGL
    - after drawing some triangles, fill them with an image - that's what a texture is. 

# an example
- https://medium.com/docler-engineering/webgl-video-manipulation-8d0892b565b6