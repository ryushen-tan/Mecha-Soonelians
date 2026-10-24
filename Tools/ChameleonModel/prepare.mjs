// Turns BlueMan's MECCHA CHAMELEON Player rig (CC BY 4.0, Sketchfab) into the app's chameleon base:
// one welded, simplified skinned mesh with fresh non-overlapping UVs (for mapping the turnaround
// photos and painting) and Mixamo bone names (for the pose wheel).
//
// Usage: node prepare.mjs <source.glb> <output.glb>
import { NodeIO } from '@gltf-transform/core';
import { prune } from '@gltf-transform/functions';
import { MeshoptSimplifier } from 'meshoptimizer';
import { Api } from 'xatlasjs/dist/node/api.mjs';
import createXAtlasModule from 'xatlasjs/dist/node/xatlas.js';
import { fileURLToPath } from 'node:url';

const [source, output] = process.argv.slice(2);
const TARGET_TRIANGLES = 20000;

// The source rig's generic bone names, by what they are. Left is +X.
const BONE_NAMES = {
  Bone_00: 'Hips', 'Bone.003_01': 'Spine', 'Bone.001_02': 'Spine1', 'Bone.004_03': 'Spine2',
  'Bone.002_04': 'Chest', 'Bone.005_05': 'UpperChest', 'Bone.006_010': 'Neck', 'Bone.011_011': 'Head',
  'Bone.011_end_018': 'HeadTop_End',
  'Bone.007_06': 'LeftArm', 'Bone.008_07': 'LeftForeArm', 'Bone.008_end_016': 'LeftHand',
  'Bone.009_08': 'RightArm', 'Bone.010_09': 'RightForeArm', 'Bone.010_end_017': 'RightHand',
  'Bone.013_012': 'LeftUpLeg', 'Bone.014_013': 'LeftLeg', 'Bone.014_end_019': 'LeftFoot',
  'Bone.015_014': 'RightUpLeg', 'Bone.016_015': 'RightLeg', 'Bone.016_end_020': 'RightFoot'
};

const io = new NodeIO();
const document = await io.read(source);
const root = document.getRoot();

// 1. Merge every primitive (Sketchfab split the body into 9 to fit 16-bit indices).
const positions = [], joints = [], weights = [], indices = [];
let skinnedNodes = root.listNodes().filter(node => node.getMesh() && node.getSkin());
for (const node of skinnedNodes) {
  for (const primitive of node.getMesh().listPrimitives()) {
    const offset = positions.length / 3;
    // Spreading 200k values overflows the stack, so append one at a time.
    for (const value of primitive.getAttribute('POSITION').getArray()) positions.push(value);
    for (const value of primitive.getAttribute('JOINTS_0').getArray()) joints.push(value);
    for (const value of primitive.getAttribute('WEIGHTS_0').getArray()) weights.push(value);
    for (const index of primitive.getIndices().getArray()) indices.push(index + offset);
  }
}
console.log('merged', positions.length / 3, 'vertices', indices.length / 3, 'triangles');

// 2. Weld vertices that share a position, so the surface is connected.
const extent = Math.max(...[0, 1, 2].map(axis => {
  let min = Infinity, max = -Infinity;
  for (let i = axis; i < positions.length; i += 3) { min = Math.min(min, positions[i]); max = Math.max(max, positions[i]); }
  return max - min;
}));
const quantum = extent * 1e-5;
const firstAt = new Map(), weld = new Uint32Array(positions.length / 3);
for (let vertex = 0; vertex < weld.length; vertex++) {
  const key = [0, 1, 2].map(axis => Math.round(positions[vertex * 3 + axis] / quantum)).join(',');
  if (!firstAt.has(key)) firstAt.set(key, vertex);
  weld[vertex] = firstAt.get(key);
}
const welded = new Uint32Array(indices.map(index => weld[index]));

// 3. Simplify to a phone-friendly size. The source surface has overlapping layers that the
// topology-preserving simplifier refuses to collapse, so use the sloppy (topology-free) one.
await MeshoptSimplifier.ready;
const positionArray = new Float32Array(positions);
const [simplified, error] = MeshoptSimplifier.simplifySloppy(welded, positionArray, 3, null, TARGET_TRIANGLES * 3, 0.05);
console.log('simplified to', simplified.length / 3, 'triangles, error', error.toFixed(4));

// Keep only the vertices still in use.
const used = new Map();
const compact = new Uint32Array(simplified.length);
simplified.forEach((vertex, i) => { if (!used.has(vertex)) used.set(vertex, used.size); compact[i] = used.get(vertex); });
const order = [...used.keys()];
const pick = (array, width) => {
  const out = new Float32Array(order.length * width);
  order.forEach((vertex, i) => { for (let c = 0; c < width; c++) out[i * width + c] = array[vertex * width + c]; });
  return out;
};
const position = pick(positions, 3), joint = pick(joints, 4), weight = pick(weights, 4);

// 4. Smooth normals.
const normal = new Float32Array(position.length);
for (let t = 0; t < compact.length; t += 3) {
  const [a, b, c] = [compact[t], compact[t + 1], compact[t + 2]];
  const e1 = [0, 1, 2].map(k => position[b * 3 + k] - position[a * 3 + k]);
  const e2 = [0, 1, 2].map(k => position[c * 3 + k] - position[a * 3 + k]);
  const n = [e1[1] * e2[2] - e1[2] * e2[1], e1[2] * e2[0] - e1[0] * e2[2], e1[0] * e2[1] - e1[1] * e2[0]];
  for (const v of [a, b, c]) for (let k = 0; k < 3; k++) normal[v * 3 + k] += n[k];
}
for (let v = 0; v < normal.length; v += 3) {
  const length = Math.hypot(normal[v], normal[v + 1], normal[v + 2]) || 1;
  for (let k = 0; k < 3; k++) normal[v + k] /= length;
}

// 5. Fresh UVs: xatlas cuts the body into charts and packs them without overlaps.
const XAtlas = Api(createXAtlasModule);
const atlasApi = await new Promise(resolve => {
  const api = new XAtlas(() => resolve(api), () => fileURLToPath(new URL('node_modules/xatlasjs/dist/node/xatlas.wasm', import.meta.url)));
});
atlasApi.createAtlas();
atlasApi.addMesh(new Uint16Array(compact), position, normal, null, 'body', true, false);
const atlas = atlasApi.generateAtlas({}, { resolution: 1024, padding: 4, bilinear: true });
const unwrapped = atlas.meshes[0];
console.log('atlas', atlas.width, 'x', atlas.height, 'charts for', unwrapped.vertexCount, 'vertices');
const remap = (array, width) => {
  const out = new Float32Array(unwrapped.vertexCount * width);
  unwrapped.oldIndexes.forEach((old, i) => { for (let c = 0; c < width; c++) out[i * width + c] = array[old * width + c]; });
  return out;
};
// xatlasjs already returns UVs normalized to 0–1.
const uv = new Float32Array(unwrapped.vertex.coords1);

// 6. Write it back into the first primitive and drop the rest.
const [keepNode, ...dropNodes] = skinnedNodes;
const primitive = keepNode.getMesh().listPrimitives()[0];
const buffer = root.listBuffers()[0];
const accessor = (array, type) => document.createAccessor().setArray(array).setType(type).setBuffer(buffer);
primitive.setAttribute('POSITION', accessor(remap(position, 3), 'VEC3'));
primitive.setAttribute('NORMAL', accessor(remap(normal, 3), 'VEC3'));
primitive.setAttribute('TEXCOORD_0', accessor(uv, 'VEC2'));
primitive.setAttribute('JOINTS_0', accessor(new Uint16Array(remap(joint, 4)), 'VEC4'));
primitive.setAttribute('WEIGHTS_0', accessor(remap(weight, 4), 'VEC4'));
primitive.setIndices(accessor(new Uint16Array(unwrapped.index), 'SCALAR'));
for (const extra of keepNode.getMesh().listPrimitives().slice(1)) extra.dispose();
for (const node of dropNodes) { node.getMesh().listPrimitives().forEach(extra => extra.dispose()); node.getMesh().dispose(); node.dispose(); }
// Double-sided hides the pinholes the sloppy simplifier leaves.
primitive.getMaterial()?.setBaseColorFactor([1, 1, 1, 1]).setRoughnessFactor(0.6).setMetallicFactor(0).setDoubleSided(true);

// 7. Mixamo bone names, so the pose wheel recognizes the body.
for (const node of root.listNodes()) if (BONE_NAMES[node.getName()]) node.setName(BONE_NAMES[node.getName()]);

// Drop everything the old primitives used.
await document.transform(prune({ keepAttributes: true }));  // keep the UVs; no texture uses them yet
await io.write(output, document);
console.log('wrote', output);
