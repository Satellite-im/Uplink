// The light the phone is seen by: a dark studio of a few soft lamps, made here (no picture is fetched), in which
// glass stays black and an edge catches a line of light. Under it, a low warm glow, as from the planet in the
// hero's picture; over it, a cold one. The phone turns in this light, so the lines travel along it.
import { BackSide, BoxGeometry, Color, DoubleSide, Mesh, MeshBasicMaterial, PlaneGeometry, Scene } from 'three';

export function makeStudio() {
  const scene = new Scene();
  const room = new Mesh(new BoxGeometry(40, 40, 40), new MeshBasicMaterial({ color: 0x030304, side: BackSide }));
  scene.add(room);
  const lamp = (w, h, x, y, z, strength, tint = 0xffffff) => {
    const m = new Mesh(new PlaneGeometry(w, h), new MeshBasicMaterial({ color: new Color(tint).multiplyScalar(strength), side: DoubleSide }));
    m.position.set(x, y, z);
    m.lookAt(0, 0, 0);
    scene.add(m);
  };
  lamp(7, 4.5, -5, 6.5, 6, 9); // the key: a wide box above the camera's left shoulder
  lamp(1.1, 11, 9, 1, 1.5, 30); // a tall strip at the right, for the edges
  lamp(0.9, 10, -9.5, -0.5, -2, 20); // and a thinner one at the left, behind
  lamp(9, 9, 0, 10, -1, 1.1, 0xbfd4ff); // the cold of the sky overhead
  lamp(14, 6, 0, -9, 3, 1.5, 0xff8a3d); // the planet's glow from below
  lamp(10, 7, 1.5, 0.5, 12, 0.32); // a little from behind the camera, so the glass is not a hole
  return scene;
}
