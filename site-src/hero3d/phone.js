// The hero's phone where there is no model of one to show: a plain foldable of our own, made here from boxes and
// curves. The site as Uplink ships it shows a real phone's model instead (./duo.js), which is not in this repository
// and not ours to pass on; anyone building the site from the source gets this one.
//
// It is NOT a model of anyone's product and borrows nothing but a size: a book-style foldable about as wide, tall
// and thin as phones of that kind are (84 x 118 mm closed, 5.2 mm a half), with a camera island, buttons and a
// spine of no maker in particular.
//
// Lengths are the app's pixels (412 of them across the outer screen), so a pane of the app laid on a screen is at its
// own size. The back half stands still at the right; the front half, which carries the outer screen, swings on the
// spine: fold 0 is shut, 1 is open flat.
import { BoxGeometry, CylinderGeometry, ExtrudeGeometry, Group, Mesh, MeshPhysicalMaterial, Object3D, Shape, ShapeGeometry } from 'three';

export const DIM = {
  PW: 436, // a half's width
  PH: 624, // its height
  T: 27, // its thickness
  G: 5, // the gap between the halves when shut
  R: 62, // the outer corners
  RH: 5, // the corners at the spine
  cover: [412, 600], // the outer screen
  inner: [836, 588], // the inner screen, both halves
};

// A rectangle with a radius of its own at each corner, anticlockwise from the bottom left.
function rrect(x0, y0, x1, y1, tl, tr, br, bl) {
  const s = new Shape();
  s.moveTo(x0 + bl, y0);
  s.lineTo(x1 - br, y0);
  if (br) s.absarc(x1 - br, y0 + br, br, -Math.PI / 2, 0, false);
  s.lineTo(x1, y1 - tr);
  if (tr) s.absarc(x1 - tr, y1 - tr, tr, 0, Math.PI / 2, false);
  s.lineTo(x0 + tl, y1);
  if (tl) s.absarc(x0 + tl, y1 - tl, tl, Math.PI / 2, Math.PI, false);
  s.lineTo(x0, y0 + bl);
  if (bl) s.absarc(x0 + bl, y0 + bl, bl, Math.PI, Math.PI * 1.5, false);
  return s;
}

// A half's body: its outline pushed through its thickness, the edges rounded over. It lies from z = -T to 0.
function slab(x0, x1, rLeft, rRight) {
  const { PH, T } = DIM, b = 2.6;
  const shape = rrect(x0 + b, -PH / 2 + b, x1 - b, PH / 2 - b, Math.max(rLeft - b, 0.5), Math.max(rRight - b, 0.5), Math.max(rRight - b, 0.5), Math.max(rLeft - b, 0.5));
  const geo = new ExtrudeGeometry(shape, { depth: T - 2 * b, bevelEnabled: true, bevelThickness: b, bevelSize: b, bevelSegments: 6, curveSegments: 32 });
  geo.translate(0, 0, -(T - b));
  return geo;
}

// A sheet of glass (or ceramic) on a half's face. `back` turns it to face away.
function plate(x0, x1, inset, rLeft, rRight, back) {
  const { PH } = DIM;
  const y0 = -PH / 2 + inset, y1 = PH / 2 - inset;
  const l = Math.max(rLeft - inset, 0), r = Math.max(rRight - inset, 0);
  if (!back) return new ShapeGeometry(rrect(x0, y0, x1, y1, l, r, r, l), 28);
  const geo = new ShapeGeometry(rrect(-x1, y0, -x0, y1, r, l, l, r), 28);
  geo.rotateY(Math.PI);
  return geo;
}

// A pill standing proud of a face, for the camera island: its outline pushed out by `h`.
function pill(w, h, r, depth) {
  const b = 1.8;
  const geo = new ExtrudeGeometry(rrect(-w / 2 + b, -h / 2 + b, w / 2 - b, h / 2 - b, r - b, r - b, r - b, r - b), { depth: depth - b, bevelEnabled: true, bevelThickness: b, bevelSize: b, bevelSegments: 4, curveSegments: 24 });
  geo.translate(0, 0, b - depth); // from z = -depth (its face) to 0 (where it meets the back)
  return geo;
}

// The finishes: a dark one for the dark page, a pale one for the light page.
const FINISH = {
  dark: { frame: 0x55565c, back: 0x141519, island: 0x0c0d10, ring: 0x3c3d42 },
  light: { frame: 0xdcdcdf, back: 0xeeede9, island: 0xdddcd8, ring: 0xc9c9cc },
};

export function makePhone() {
  const { PW, PH, T, G, R, RH, cover, inner } = DIM;
  const m = {
    frame: new MeshPhysicalMaterial({ color: FINISH.dark.frame, metalness: 1, roughness: 0.3 }),
    spine: new MeshPhysicalMaterial({ color: FINISH.dark.frame, metalness: 1, roughness: 0.42 }),
    back: new MeshPhysicalMaterial({ color: FINISH.dark.back, metalness: 0, roughness: 0.46, clearcoat: 0.6, clearcoatRoughness: 0.3 }),
    // The outer glass shines; the inner one, which bends, is matte.
    glass: new MeshPhysicalMaterial({ color: 0x020203, metalness: 0, roughness: 0.07, clearcoat: 1, clearcoatRoughness: 0.04 }),
    soft: new MeshPhysicalMaterial({ color: 0x030304, metalness: 0, roughness: 0.86, envMapIntensity: 0.55 }),
    island: new MeshPhysicalMaterial({ color: FINISH.dark.island, metalness: 0, roughness: 0.22, clearcoat: 1, clearcoatRoughness: 0.08 }),
    ring: new MeshPhysicalMaterial({ color: FINISH.dark.ring, metalness: 1, roughness: 0.26 }),
    lens: new MeshPhysicalMaterial({ color: 0x010102, metalness: 0, roughness: 0.03, clearcoat: 1, clearcoatRoughness: 0.02 }),
    iris: new MeshPhysicalMaterial({ color: 0x0a1020, metalness: 0.6, roughness: 0.2 }),
    port: new MeshPhysicalMaterial({ color: 0x050506, metalness: 0.2, roughness: 0.6 }),
  };
  const mesh = (geo, mat, parent, x = 0, y = 0, z = 0) => { const o = new Mesh(geo, mat); o.position.set(x, y, z); parent.add(o); return o; };
  const lip = 1.4; // the frame showing round the glass

  const group = new Group();

  // --- the back half: still, at the right; its inner face at z = 0 ---------------------------------------------
  const rear = new Group();
  group.add(rear);
  mesh(slab(0, PW, RH, R), m.frame, rear);
  mesh(plate(0, PW - lip, lip, 0, R, false), m.soft, rear, 0, 0, 0.12); // its half of the inner screen
  mesh(plate(lip, PW - lip, lip, RH, R, true), m.back, rear, 0, 0, -T - 0.12); // its back
  // The camera island, in the top corner away from the spine: two lenses in a pill, a lamp beside it.
  const island = new Group();
  island.position.set(PW - 76, PH / 2 - 128, -T);
  rear.add(island);
  mesh(pill(92, 188, 46, 6.5), m.island, island);
  for (const y of [47, -47]) {
    const ring = mesh(new CylinderGeometry(33, 33, 4.5, 48), m.ring, island, 0, y, -8.5);
    ring.rotation.x = Math.PI / 2;
    const glass = mesh(new CylinderGeometry(27, 27, 1.2, 48), m.lens, island, 0, y, -10.9);
    glass.rotation.x = Math.PI / 2;
    const iris = mesh(new CylinderGeometry(11, 11, 0.6, 32), m.iris, island, 0, y, -11.3);
    iris.rotation.x = Math.PI / 2;
  }
  const lamp = mesh(new CylinderGeometry(9, 9, 1.2, 32), m.ring, rear, PW - 152, PH / 2 - 62, -T - 0.6);
  lamp.rotation.x = Math.PI / 2;
  // Two buttons on its outer edge, and the port at its foot.
  mesh(new BoxGeometry(4.5, 62, 8.5), m.frame, rear, PW + 0.6, 92, -T / 2);
  mesh(new BoxGeometry(4.5, 104, 8.5), m.frame, rear, PW + 0.6, 198, -T / 2);
  mesh(new BoxGeometry(44, 3, 8), m.port, rear, PW / 2, -PH / 2 + 0.9, -T / 2);

  // --- the front half: swings on the spine; laid open it lies at the left -------------------------------------
  const pivot = new Group();
  pivot.position.set(0, 0, G / 2);
  group.add(pivot);
  const front = new Group();
  front.position.set(0, 0, -G / 2);
  pivot.add(front);
  mesh(slab(-PW, 0, R, RH), m.frame, front);
  mesh(plate(-PW + lip, 0, lip, R, 0, false), m.soft, front, 0, 0, 0.12); // its half of the inner screen
  mesh(plate(-PW + lip, -lip, lip, R, RH, true), m.glass, front, 0, 0, -T - 0.12); // the outer screen's glass

  // --- the spine: a low rounded cover on the hinge, turning half as far as the front half -----------------------
  // Open, it lies inside the two halves; shut, it is the back of the book, and stands out no more than a
  // couple of millimetres, so that shut the phone is a D: flat at the hinge, round at the open side.
  const rho = T + G / 2 - 0.7, d = G / 2 + 0.9, a = Math.acos(d / rho), rise = 0.42;
  const arc = new Shape();
  arc.absarc(0, 0, rho, -Math.PI / 2 - a, -Math.PI / 2 + a, false);
  // The arc is a half round; pressed toward its flat side it is the low cover.
  const seg = new Shape(arc.getPoints(40).map((p) => { p.y = -d + (p.y + d) * rise; return p; }));
  const spineGeo = new ExtrudeGeometry(seg, { depth: PH - 26, bevelEnabled: false, curveSegments: 28 });
  // Drawn in x and y and pushed along z; turned so it runs up the hinge with its round side to the back.
  spineGeo.translate(0, 0, -(PH - 26) / 2);
  spineGeo.rotateX(Math.PI / 2); // y (the round side) to -z; z to y
  const spine = mesh(spineGeo, m.spine, group, 0, 0, G / 2);

  // --- where the app's screens lie ---------------------------------------------------------------------------
  const anchors = { cover: new Object3D(), innerL: new Object3D(), innerR: new Object3D() };
  anchors.cover.position.set(-PW / 2, 0, -T - 0.5);
  anchors.cover.rotation.y = Math.PI;
  front.add(anchors.cover);
  anchors.innerL.position.set(-inner[0] / 4, 0, 0.5);
  front.add(anchors.innerL);
  anchors.innerR.position.set(inner[0] / 4, 0, 0.5);
  rear.add(anchors.innerR);

  let fold = -1;
  const phone = {
    group, anchors, materials: m,
    dim: { PW, PH },
    /** 0 shut, 1 open flat. */
    setFold(f) {
      if (f === fold) return;
      fold = f;
      const turn = (1 - f) * Math.PI;
      pivot.rotation.y = turn;
      spine.rotation.y = turn / 2;
    },
    /** The middle of what is seen of it, for the camera to look at. */
    centre(f, out) {
      const turn = (1 - f) * Math.PI;
      const left = Math.min(0, -PW * Math.cos(turn));
      out.set((PW + left) / 2, 0, (PW * Math.sin(turn)) * 0.18 + (1 - f) * (G / 2) - f * (T / 2));
      return out;
    },
    /** How much room it takes, across and up, for fitting it to the stage. */
    span(f) {
      const turn = (1 - f) * Math.PI;
      const left = Math.min(0, -PW * Math.cos(turn));
      return [PW - left, PH];
    },
    setFinish(light) {
      const c = light ? FINISH.light : FINISH.dark;
      m.frame.color.setHex(c.frame); m.spine.color.setHex(c.frame); m.back.color.setHex(c.back); m.island.color.setHex(c.island); m.ring.color.setHex(c.ring);
    },
  };
  phone.setFold(0);
  // The screens' sizes, for whoever lays the app on them.
  phone.screens = { cover, innerL: [inner[0] / 2, inner[1]], innerR: [inner[0] / 2, inner[1]] };
  return phone;
}
