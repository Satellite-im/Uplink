// The phone the hero shows where its model is there to be shown: /model/duo.bin, which tool/hero3d-model.py packs
// from a model that is not in this repository (a real phone's, which Uplink may show but not pass on; see that
// script). Without the file the hero draws the plain foldable of ./phone.js instead.
//
// The file holds the phone open: the right half's parts (R), the left half's (L), and the few parts that bend
// (D_*), each of whose vertices also says where it is when the phone is shut. As it shuts each half turns a quarter
// about its own hinge line, the left one way and the right the other. Here the right half is kept still instead
// (the camera's score in main.js is written for a phone whose back half stands still), so the left half turns a
// half turn about it and what bends is carried between its two shapes about the hinge.
//
// What it answers to is what ./phone.js answers to: group, anchors, screens, setFold, centre, span, setFinish.
import { DynamicDrawUsage, Group, Matrix4, Object3D } from 'three';
import { GLTFLoader } from 'three/addons/loaders/GLTFLoader.js';

/** The outer screen's width in the app's pixels: everything is scaled so that it is exactly this. */
const COVER = 412;

export async function loadDuo(url) {
  // The file is a GLB, gzipped by the script that packs it (the server sends such a file as it is): unpacked here.
  const got = await fetch(url);
  if (!got.ok || !got.body || typeof DecompressionStream === 'undefined') throw new Error('no model at ' + url);
  const glb = await new Response(got.body.pipeThrough(new DecompressionStream('gzip'))).arrayBuffer();
  const gltf = await new GLTFLoader().parseAsync(glb, '');
  const info = gltf.scene.userData;
  if (!info || !info.cover || !info.hingeLeft) throw new Error('not the phone tool/hero3d-model.py packs');
  const S = COVER / (info.cover.max[0] - info.cover.min[0]); // pixels to a metre
  const innerZ = info.inner.max[2];
  const cL = info.hingeLeft, cR = info.hingeRight; // each hinge line's x and z

  // The file's own lengths and places, scaled; the inner screen's glass at z = 0, as ./phone.js has it.
  const model = new Group();
  model.scale.setScalar(S);
  model.position.set(0, 0, -innerZ * S);
  const left = new Group(), bent = new Group();
  left.matrixAutoUpdate = bent.matrixAutoUpdate = false;
  model.add(left, bent);
  const group = new Group();
  group.add(model);

  // A finish for the dark page and one for the light: every mesh has both.
  const finishes = [];
  const bends = [];
  const jobs = [];
  for (const node of [...gltf.scene.children]) {
    const rigid = node.name === 'R' ? model : node.name === 'L' ? left : null;
    (rigid || bent).add(node);
    // The inner screen's border is under the same matte coat as the screen it frames, though the file gives it the
    // outer glass's material.
    const matte = node.name === 'D_Inner_Display_Bezel';
    node.traverse((mesh) => {
      if (!mesh.isMesh) return;
      const entry = { mesh, light: tune(mesh.material, matte), dark: null };
      entry.dark = entry.light;
      mesh.material = entry.light;
      finishes.push(entry);
      // Its Night Sky material: the file says which on each piece of geometry (extras.night).
      const night = mesh.geometry.userData.night;
      if (night != null) jobs.push(gltf.parser.getDependency('material', night).then((m) => { entry.dark = tune(m, matte); }));
      if (!rigid) bends.push(bend(mesh, cL, cR));
    });
  }
  await Promise.all(jobs);

  // Where the app's screens lie: the outer one on the left half's back, the inner one's halves on each half.
  const mid = (r, i) => (r.min[i] + r.max[i]) / 2;
  const lift = 0.5 / S; // half a pixel off the glass
  const anchors = { cover: new Object3D(), innerL: new Object3D(), innerR: new Object3D() };
  anchors.cover.position.set(mid(info.cover, 0), mid(info.cover, 1), info.cover.min[2] - lift);
  anchors.cover.rotation.y = Math.PI;
  anchors.cover.scale.setScalar(1 / S);
  const half = (info.inner.max[0] - info.inner.min[0]) / 2, INNER = 418;
  const k = (half * S) / INNER / S; // the app's half page is 418 across; the glass may be a hair more or less
  anchors.innerL.position.set(info.inner.min[0] / 2, mid(info.inner, 1), innerZ + lift);
  anchors.innerL.scale.setScalar(k);
  anchors.innerR.position.set(info.inner.max[0] / 2, mid(info.inner, 1), innerZ + lift);
  anchors.innerR.scale.setScalar(k);
  left.add(anchors.cover, anchors.innerL);
  model.add(anchors.innerR);

  const PW = info.body.max[0] * S, PH = (info.cover.max[1] - info.cover.min[1]) * S * (117.8 / 112.4);
  const turnAbout = (c, angle, out) => out.makeTranslation(c[0], 0, c[1]).multiply(m1.makeRotationY(angle)).multiply(m2.makeTranslation(-c[0], 0, -c[1]));
  const m1 = new Matrix4(), m2 = new Matrix4(), fix = new Matrix4(), swing = new Matrix4();
  let fold = -1;
  const phone = {
    group, anchors,
    dim: { PW, PH },
    screens: { cover: [COVER, 600], innerL: [INNER, 588], innerR: [INNER, 588] },
    /** 0 shut, 1 open flat. */
    setFold(f) {
      if (f === fold) return;
      fold = f;
      const quarter = (1 - f) * Math.PI / 2;
      // The right half would turn back a quarter about its hinge; everything else is turned forward by as much
      // about that same line, which leaves the right half where it is.
      turnAbout(cR, quarter, fix);
      bent.matrix.copy(fix);
      left.matrix.copy(fix).multiply(turnAbout(cL, quarter, swing));
      left.matrixWorldNeedsUpdate = bent.matrixWorldNeedsUpdate = true;
      for (const b of bends) b(1 - f);
    },
    centre(f, out) {
      const turn = (1 - f) * Math.PI;
      const leftmost = Math.min(0, -PW * Math.cos(turn));
      return out.set((PW + leftmost) / 2, 0, PW * Math.sin(turn) * 0.18 + (1 - f) * 1 - f * 14);
    },
    span(f) {
      const turn = (1 - f) * Math.PI;
      return [PW - Math.min(0, -PW * Math.cos(turn)), PH];
    },
    setFinish(light) {
      for (const e of finishes) e.mesh.material = light ? e.light : e.dark;
    },
  };
  phone.setFold(0);
  return phone;
}

// What three makes of the file's materials, set for this page: a clear cover is not written to the depth it is seen
// through; the inner screen is matte, as the phone's is (Matt, 2026-11-27: "the inner screen is too shiny it should
// be matte"), and the outer glass, dark, mirrors the lamps a little less than a camera's flash would have it.
const mattes = new Map();
function tune(m, matte) {
  if (matte) {
    if (!mattes.has(m)) { const c = m.clone(); c.name = m.name + ' (matte)'; mattes.set(m, soften(c)); }
    return mattes.get(m);
  }
  if (m.userData.tuned) return m;
  m.userData.tuned = true;
  if (m.transparent) m.depthWrite = false;
  if (/Inner_OLED/.test(m.name)) soften(m);
  else if (/Outer_OLED|Display_Black_Glass/.test(m.name)) m.envMapIntensity = 0.6;
  return m;
}
function soften(m) {
  m.roughness = 0.86;
  m.envMapIntensity = 0.55;
  if ('clearcoat' in m) { m.clearcoat = 0; m.clearcoatRoughness = 1; }
  return m;
}

// A part that bends: each vertex goes from where it is open to where it is shut round its own side's hinge line,
// its distance from the line and its angle about it both carried evenly, so a vertex of a rigid stretch turns as the
// half it belongs to does and one in the fold curls. Returns what moves it: `u` 0 open, 1 shut.
function bend(mesh, cL, cR) {
  const g = mesh.geometry, pos = g.attributes.position, nor = g.attributes.normal, shut = g.attributes._closed;
  const n = pos.count;
  const open = Float32Array.from(pos.array), normals = Float32Array.from(nor.array);
  const cx = new Float32Array(n), cz = new Float32Array(n), r0 = new Float32Array(n), dr = new Float32Array(n), a0 = new Float32Array(n), da = new Float32Array(n);
  for (let i = 0; i < n; i++) {
    const x = open[3 * i], z = open[3 * i + 2], xs = shut.getX(i), zs = shut.getZ(i);
    const side = x < -1e-6 ? -1 : x > 1e-6 ? 1 : 0;
    cx[i] = side < 0 ? cL[0] : side > 0 ? cR[0] : 0;
    cz[i] = side < 0 ? cL[1] : cR[1];
    const ro = Math.hypot(x - cx[i], z - cz[i]), rs = Math.hypot(xs - cx[i], zs - cz[i]);
    const ao = Math.atan2(z - cz[i], x - cx[i]), as = Math.atan2(zs - cz[i], xs - cx[i]);
    // The left side's angle falls a quarter turn, the right side's rises one: of the ways round, the one nearest that.
    const want = (side * Math.PI) / 2;
    let d = as - ao;
    d += 2 * Math.PI * Math.round((want - d) / (2 * Math.PI));
    r0[i] = ro; dr[i] = rs - ro; a0[i] = ao; da[i] = ro < 1e-7 || rs < 1e-7 ? 0 : d;
  }
  pos.setUsage(DynamicDrawUsage);
  nor.setUsage(DynamicDrawUsage);
  mesh.frustumCulled = false;
  return (u) => {
    const p = pos.array, q = nor.array;
    for (let i = 0; i < n; i++) {
      const a = a0[i] + u * da[i], r = r0[i] + u * dr[i];
      p[3 * i] = cx[i] + r * Math.cos(a);
      p[3 * i + 2] = cz[i] + r * Math.sin(a);
      const t = u * da[i], c = Math.cos(t), s = Math.sin(t), nx = normals[3 * i], nz = normals[3 * i + 2];
      q[3 * i] = nx * c - nz * s;
      q[3 * i + 2] = nx * s + nz * c;
    }
    pos.needsUpdate = nor.needsUpdate = true;
  };
}
