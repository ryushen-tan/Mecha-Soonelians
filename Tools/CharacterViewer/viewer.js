import * as THREE from 'three';
import { OrbitControls } from 'three/addons/controls/OrbitControls.js';
import { GLTFLoader } from 'three/addons/loaders/GLTFLoader.js';
import { GLTFExporter } from 'three/addons/exporters/GLTFExporter.js';
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
  async exportModel() {
    try {
      if (!character) throw new Error('Load a model first.');
      renderer.render(scene, camera);
      const thumbnail = renderer.domElement.toDataURL('image/png').split(',')[1];
      const result = await new GLTFExporter().parseAsync(character, { binary: true, onlyVisible: false, trs: true });
      const bytes = new Uint8Array(result);
      let encoded = '';
      for (let offset = 0; offset < bytes.length; offset += 32768) encoded += String.fromCharCode(...bytes.subarray(offset, offset + 32768));
      post('exported', { model: btoa(encoded), thumbnail });
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
