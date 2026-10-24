import * as THREE from 'three';
import { OrbitControls } from 'three/addons/controls/OrbitControls.js';
import { GLTFLoader } from 'three/addons/loaders/GLTFLoader.js';
import { GLTFExporter } from 'three/addons/exporters/GLTFExporter.js';
import { USDZExporter } from 'three/addons/exporters/USDZExporter.js';
import { MeshoptDecoder } from 'three/addons/libs/meshopt_decoder.module.js';

const post = (type, value) => window.webkit?.messageHandlers.character.postMessage({ type, value });
const status = document.getElementById('status');
window.addEventListener('error', event => { status.textContent = '3D viewer error.'; post('error', event.message); });
const scene = new THREE.Scene();
scene.background = new THREE.Color('#f0f0e7');
const camera = new THREE.PerspectiveCamera(38, 1, 0.01, 1000);
const renderer = new THREE.WebGLRenderer({ antialias: true, preserveDrawingBuffer: true });
renderer.setPixelRatio(Math.min(devicePixelRatio, 2));
renderer.toneMapping = THREE.ACESFilmicToneMapping;
document.body.appendChild(renderer.domElement);
const controls = new OrbitControls(camera, renderer.domElement);
controls.enableDamping = true;
scene.add(new THREE.HemisphereLight(0xffffff, 0x8e947f, 2.5));
const light = new THREE.DirectionalLight(0xffffff, 3);
light.position.set(3, 5, 4);
scene.add(light);
const fill = new THREE.DirectionalLight(0xffffff, 2);
fill.position.set(-3, 2, -4);
scene.add(fill);
let character;
let bones = [];
let rest = [];
let skeleton;
let radius = 1;

// Painting: each base-color texture is copied to a canvas that strokes draw into.
const paintTargets = new Map();
const undoStack = [];
const raycaster = new THREE.Raycaster();
const brush = { color: '#808080', size: 0.02 };
let painting = false;
let lastDab = null;

function encodeBase64(bytes) {
  let encoded = '';
  for (let offset = 0; offset < bytes.length; offset += 32768) encoded += String.fromCharCode(...bytes.subarray(offset, offset + 32768));
  return btoa(encoded);
}

function makePaintable() {
  paintTargets.clear();
  undoStack.length = 0;
  character.traverse(node => {
    if (!node.isMesh) return;
    for (const material of Array.isArray(node.material) ? node.material : [node.material]) {
      const map = material.map;
      if (!map?.image) continue;
      let target = paintTargets.get(map.uuid);
      if (!target) {
        const canvas = document.createElement('canvas');
        canvas.width = map.image.width;
        canvas.height = map.image.height;
        const context = canvas.getContext('2d', { willReadFrequently: true });
        context.drawImage(map.image, 0, 0);
        const texture = new THREE.CanvasTexture(canvas);
        for (const key of ['flipY', 'colorSpace', 'wrapS', 'wrapT', 'channel', 'magFilter', 'minFilter']) texture[key] = map[key];
        target = { canvas, context, texture };
        paintTargets.set(map.uuid, target);
      }
      material.map = target.texture;
      material.userData.paintTarget = target;
      material.needsUpdate = true;
    }
  });
}

function pointerHit(event) {
  const rect = renderer.domElement.getBoundingClientRect();
  const pointer = new THREE.Vector2(((event.clientX - rect.left) / rect.width) * 2 - 1, -((event.clientY - rect.top) / rect.height) * 2 + 1);
  raycaster.setFromCamera(pointer, camera);
  const hit = raycaster.intersectObject(character, true)[0];
  if (!hit?.uv) return null;
  const material = Array.isArray(hit.object.material) ? hit.object.material[hit.face.materialIndex] : hit.object.material;
  const target = material?.userData.paintTarget;
  if (!target) return null;
  const u = hit.uv.x - Math.floor(hit.uv.x);
  const v = hit.uv.y - Math.floor(hit.uv.y);
  const { width, height } = target.canvas;
  return { target, x: u * width, y: (target.texture.flipY ? 1 - v : v) * height };
}

function dab(hit) {
  const { context, canvas, texture } = hit.target;
  const radius = Math.max(1, brush.size * canvas.width);
  context.strokeStyle = context.fillStyle = brush.color;
  context.lineWidth = radius * 2;
  context.lineCap = 'round';
  // Join to the previous dab unless it jumped across a texture seam.
  if (lastDab && lastDab.target === hit.target && Math.hypot(lastDab.x - hit.x, lastDab.y - hit.y) < radius * 6) {
    context.beginPath();
    context.moveTo(lastDab.x, lastDab.y);
    context.lineTo(hit.x, hit.y);
    context.stroke();
  } else {
    context.beginPath();
    context.arc(hit.x, hit.y, radius, 0, Math.PI * 2);
    context.fill();
  }
  texture.needsUpdate = true;
  lastDab = hit;
}

renderer.domElement.addEventListener('pointerdown', event => {
  if (!painting || !character) return;
  const hit = pointerHit(event);
  if (!hit) return;
  undoStack.push([...paintTargets.values()].map(target => [target, target.context.getImageData(0, 0, target.canvas.width, target.canvas.height)]));
  if (undoStack.length > 5) undoStack.shift();
  lastDab = null;
  dab(hit);
  try { renderer.domElement.setPointerCapture(event.pointerId); } catch {}
});
renderer.domElement.addEventListener('pointermove', event => {
  if (!painting || !character || !renderer.domElement.hasPointerCapture(event.pointerId)) return;
  const hit = pointerHit(event);
  if (hit) dab(hit); else lastDab = null;
});
renderer.domElement.addEventListener('pointerup', () => { lastDab = null; });

/// A static copy of the character in its current pose, for exporters that don't support skinning.
function bakedCopy() {
  character.updateMatrixWorld(true);
  const group = new THREE.Group();
  const vertex = new THREE.Vector3();
  character.traverse(node => {
    if (!node.isMesh || !node.visible) return;
    const geometry = node.geometry.clone();
    if (node.isSkinnedMesh) {
      const source = node.geometry.attributes.position;
      const position = geometry.attributes.position;
      for (let index = 0; index < source.count; index++) {
        vertex.fromBufferAttribute(source, index);
        node.applyBoneTransform(index, vertex);
        position.setXYZ(index, vertex.x, vertex.y, vertex.z);
      }
      geometry.deleteAttribute('skinIndex');
      geometry.deleteAttribute('skinWeight');
      geometry.computeVertexNormals();
    }
    geometry.applyMatrix4(node.matrixWorld);
    group.add(new THREE.Mesh(geometry, node.material));
  });
  return group;
}

function fit() {
  const box = new THREE.Box3().setFromObject(character);
  const center = box.getCenter(new THREE.Vector3());
  radius = Math.max(box.getSize(new THREE.Vector3()).length() / 2, 0.1);
  controls.target.copy(center);
  camera.position.copy(center).add(new THREE.Vector3(0, radius * 0.2, radius * 3.4));
  camera.near = radius / 100;
  camera.far = radius * 100;
  camera.updateProjectionMatrix();
  controls.minDistance = radius * 0.5;
  controls.maxDistance = radius * 12;
  controls.update();
}

function validateGLB(buffer) {
  const view = new DataView(buffer);
  if (buffer.byteLength < 20 || view.getUint32(0, true) !== 0x46546c67 || view.getUint32(4, true) !== 2) throw new Error('Not a GLB 2.0 model.');
  if (view.getUint32(8, true) !== buffer.byteLength || view.getUint32(16, true) !== 0x4e4f534a) throw new Error('Invalid GLB container.');
  const length = view.getUint32(12, true);
  const json = JSON.parse(new TextDecoder().decode(new Uint8Array(buffer, 20, length)));
  for (const item of [...(json.images ?? []), ...(json.buffers ?? [])]) {
    if (item.uri && !item.uri.startsWith('data:')) throw new Error('Only self-contained models are supported.');
  }
}

window.characterViewer = {
  async load(base64, attribution) {
    try {
      const bytes = Uint8Array.from(atob(base64), character => character.charCodeAt(0));
      validateGLB(bytes.buffer);
      const manager = new THREE.LoadingManager();
      manager.setURLModifier(url => {
        if (!url.startsWith('blob:') && !url.startsWith('data:')) throw new Error('External model resources are blocked.');
        return url;
      });
      const gltf = await new GLTFLoader(manager).setMeshoptDecoder(MeshoptDecoder).parseAsync(bytes.buffer, '');
      if (character) scene.remove(character);
      if (skeleton) scene.remove(skeleton);
      character = gltf.scene;
      if (attribution) character.userData.sourceAttribution = attribution;
      scene.add(character);
      const weightedBones = new Set();
      character.traverse(node => {
        if (node.isSkinnedMesh) for (const bone of node.skeleton.bones) weightedBones.add(bone);
      });
      bones = [...weightedBones];
      rest = bones.map(bone => bone.quaternion.clone());
      skeleton = new THREE.SkeletonHelper(character);
      skeleton.visible = false;
      scene.add(skeleton);
      makePaintable();
      fit();
      status.textContent = '';
      post('loaded', bones.map((bone, index) => ({ id: index, name: bone.name || `Joint ${index + 1}` })));
    } catch (error) { status.textContent = 'Could not display this model.'; post('error', error.message); }
  },
  pose(angles, yaw, showSkeleton) {
    if (!character) return;
    bones.forEach((bone, index) => {
      const rotation = angles[index] ?? [0, 0, 0];
      const delta = new THREE.Quaternion().setFromEuler(new THREE.Euler(...rotation.map(THREE.MathUtils.degToRad), 'XYZ'));
      bone.quaternion.copy(rest[index]).multiply(delta);
    });
    character.rotation.y = THREE.MathUtils.degToRad(yaw);
    character.updateMatrixWorld(true);
    skeleton.visible = showSkeleton;
  },
  resetCamera() { if (character) fit(); },
  // One finger paints instead of orbiting while painting is on.
  setPainting(on) {
    painting = on;
    controls.enabled = !on;
  },
  setBrush(color, size) {
    brush.color = color;
    brush.size = size;
  },
  undoPaint() {
    const snapshot = undoStack.pop();
    if (!snapshot) return;
    for (const [target, image] of snapshot) {
      target.context.putImageData(image, 0, 0);
      target.texture.needsUpdate = true;
    }
  },
  async exportUSDZ() {
    try {
      if (!character) throw new Error('Load a model first.');
      const result = await new USDZExporter().parseAsync(bakedCopy(), { includeAnchoringProperties: false, maxTextureSize: 1024 });
      post('usdz', encodeBase64(new Uint8Array(result)));
    } catch (error) { post('error', error.message); }
  },
  async exportModel() {
    try {
      if (!character) throw new Error('Load a model first.');
      renderer.render(scene, camera);
      const thumbnail = renderer.domElement.toDataURL('image/png').split(',')[1];
      const result = await new GLTFExporter().parseAsync(character, { binary: true, onlyVisible: false, trs: true });
      post('exported', { model: encodeBase64(new Uint8Array(result)), thumbnail });
    } catch (error) { post('error', error.message); }
  }
};
new ResizeObserver(() => {
  const width = document.documentElement.clientWidth;
  const height = document.documentElement.clientHeight;
  renderer.setSize(width, height);
  camera.aspect = width / height;
  camera.updateProjectionMatrix();
}).observe(document.body);
renderer.setAnimationLoop(() => { controls.update(); renderer.render(scene, camera); });
post('ready', true);
