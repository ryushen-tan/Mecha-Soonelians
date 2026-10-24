import * as THREE from 'three';
import { OrbitControls } from 'three/addons/controls/OrbitControls.js';
import { GLTFLoader } from 'three/addons/loaders/GLTFLoader.js';
import { GLTFExporter } from 'three/addons/exporters/GLTFExporter.js';
import { MeshoptDecoder } from 'three/addons/libs/meshopt_decoder.module.js';
import { clone as cloneSkeleton } from 'three/addons/utils/SkeletonUtils.js';
import { HumanoidRig, posePages } from './rig.js';
import { SurfacePainter } from './paint.js';
import { RoomStage } from './room.js';
import { buildBodyForms } from './forms.js';

const post = (type, value) => window.webkit?.messageHandlers.character.postMessage({ type, value });
const status = document.getElementById('status');
window.addEventListener('error', event => { status.textContent = '3D viewer error.'; post('error', event.message); });
const scene = new THREE.Scene();
scene.background = new THREE.Color('#f0f0e7');
const camera = new THREE.PerspectiveCamera(38, 1, 0.01, 1000);
const renderer = new THREE.WebGLRenderer({ antialias: true, preserveDrawingBuffer: true });
renderer.setPixelRatio(Math.min(devicePixelRatio, 2));
renderer.toneMapping = THREE.ACESFilmicToneMapping;
renderer.shadowMap.enabled = true;
renderer.shadowMap.type = THREE.PCFSoftShadowMap;
renderer.domElement.tabIndex = 0;
document.body.appendChild(renderer.domElement);
const controls = new OrbitControls(camera, renderer.domElement);
controls.enableDamping = true;
scene.add(new THREE.HemisphereLight(0xffffff, 0x8e947f, 2));
const light = new THREE.DirectionalLight(0xffffff, 2.5);
light.position.set(3, 6, -4);
light.castShadow = true;
light.shadow.mapSize.set(1024, 1024);
light.shadow.normalBias = 0.025;
light.shadow.camera.left = light.shadow.camera.bottom = -5;
light.shadow.camera.right = light.shadow.camera.top = 5;
scene.add(light);
const fill = new THREE.DirectionalLight(0xffffff, 1.5);
fill.position.set(-3, 2, 4);
scene.add(fill);
const floorShadow = new THREE.Mesh(new THREE.PlaneGeometry(20, 20), new THREE.ShadowMaterial({ opacity: 0.18 }));
floorShadow.rotation.x = -Math.PI / 2;
floorShadow.position.y = -0.01;
floorShadow.receiveShadow = true;
scene.add(floorShadow);
const stage = new RoomStage(scene);
const placement = new THREE.Group();
const orientation = new THREE.Group();
placement.add(orientation);
scene.add(placement);
let character, rig, painter, skeleton;
let radius = 1;
let geometryDirty = true;
let settings = { preset: 'original', tool: 'orbit', color: '#d4ed5e', brush: 0.035, opacity: 1, metallic: 0,
  roughness: 0.8, shadows: true, room: false, scale: 1, form: 'person', position: [0, 0, 0], rotation: [0, 0, 0, 1] };
let lastPose = '', lastAngles = '', lastYaw = 0;
let cloneRecords = [];
const remoteGroups = new Map();
const raycaster = new THREE.Raycaster();
const pointers = new Set();
let previousPointer;
let aimDrag;
let pendingFit = false;
let pendingAssessment = false;

function visible(object) {
  for (let node = object; node; node = node.parent) if (!node.visible) return false;
  return true;
}

function visibleBounds(root) {
  const bounds = new THREE.Box3();
  const vertex = new THREE.Vector3();
  root.updateMatrixWorld(true);
  root.traverse(mesh => {
    if (!mesh.isMesh) return;
    for (let node = mesh; node && node !== root; node = node.parent) if (!node.visible) return;
    if (mesh.isSkinnedMesh) mesh.skeleton.update();
    for (let index = 0; index < mesh.geometry.attributes.position.count; index++) {
      mesh.getVertexPosition(index, vertex).applyMatrix4(mesh.matrixWorld);
      bounds.expandByPoint(vertex);
    }
  });
  return bounds;
}

function fit(roomView = false, preserveAngle = false) {
  if (!character) return;
  const box = visibleBounds(placement);
  const center = box.getCenter(new THREE.Vector3());
  radius = Math.max(box.getSize(new THREE.Vector3()).length() / 2, 0.1);
  const direction = preserveAngle ? camera.position.clone().sub(controls.target).normalize()
    : rig.forward.clone().addScaledVector(rig.right, 0.16).add(new THREE.Vector3(0, 0.07, 0)).applyQuaternion(character.getWorldQuaternion(new THREE.Quaternion())).normalize();
  controls.target.copy(center);
  camera.position.copy(center).addScaledVector(direction, radius * (roomView ? 5 : 3.4));
  camera.near = radius / 100;
  camera.far = 1000;
  camera.updateProjectionMatrix();
  controls.minDistance = radius * 0.25;
  controls.maxDistance = 30;
  controls.update();
}

function geometryFrame() {
  if (!character || !geometryDirty) return;
  orientation.position.y = 0;
  placement.updateMatrixWorld(true);
  const inverse = placement.matrixWorld.clone().invert();
  let minimum = Infinity;
  const vertex = new THREE.Vector3();
  character.traverse(mesh => {
    if (!mesh.isMesh || !mesh.visible) return;
    if (mesh.isSkinnedMesh) mesh.skeleton.update();
    for (let index = 0; index < mesh.geometry.attributes.position.count; index++) {
      mesh.getVertexPosition(index, vertex).applyMatrix4(mesh.matrixWorld).applyMatrix4(inverse);
      minimum = Math.min(minimum, vertex.y);
    }
  });
  if (Number.isFinite(minimum)) orientation.position.y = -minimum;
  placement.updateMatrixWorld(true);
  character.traverse(mesh => { if (mesh.isSkinnedMesh) { mesh.skeleton.update(); mesh.computeBoundingSphere(); } });
  painter.invalidate();
  geometryDirty = false;
}

function setAppearance() {
  character?.traverse(node => {
    if (!node.isMesh) return;
    node.visible = (node.userData.form ?? 'person') === settings.form;
    node.castShadow = settings.shadows;
    node.renderOrder = settings.xray ? 2 : 0;
    const materials = Array.isArray(node.material) ? node.material : [node.material];
    materials.forEach(material => {
      const changed = Boolean(material.metalnessMap || material.roughnessMap);
      material.metalnessMap = null;
      material.roughnessMap = null;
      material.metalness = THREE.MathUtils.clamp(settings.metallic, 0, 1);
      material.roughness = THREE.MathUtils.clamp(settings.roughness, 0.05, 1);
      material.depthTest = !settings.xray;
      if (changed) material.needsUpdate = true;
    });
  });
  floorShadow.visible = settings.shadows && !settings.room;
  stage.show(settings.room);
}

function notifyPaint() { post('painted', { ...painter.history(), checksum: painter.checksum() }); }

function hitAt(horizontal, vertical, objects = [character]) {
  geometryFrame(); scene.updateMatrixWorld(true); camera.updateMatrixWorld(true);
  raycaster.setFromCamera(new THREE.Vector2(horizontal, vertical), camera);
  return raycaster.intersectObjects(objects.filter(Boolean), true).find(hit => {
    if (!hit.object.isMesh) return false;
    return visible(hit.object);
  });
}

function pointerPosition(event) {
  const bounds = renderer.domElement.getBoundingClientRect();
  return { x: (event.clientX - bounds.left) / bounds.width * 2 - 1, y: 1 - (event.clientY - bounds.top) / bounds.height * 2 };
}

function paintPoint(horizontal, vertical) {
  const hit = hitAt(horizontal, vertical);
  if (!hit) return false;
  return painter.stamp(hit, settings.color, settings.brush * 1.75 * settings.scale, settings.opacity, settings.tool === 'erase');
}

function pointerAction(event) {
  if (!character || pointers.size > 1 || (settings.frozen && ['paint', 'erase', 'attach'].includes(settings.tool))) return;
  const coordinate = pointerPosition(event);
  if (settings.tool === 'sample') {
    const hit = hitAt(coordinate.x, coordinate.y, settings.room ? [character, stage.room] : [character]);
    if (hit) post('sampled', painter.sample(hit));
  } else if (settings.tool === 'attach') {
    const hit = hitAt(coordinate.x, coordinate.y, [stage.room]);
    if (hit) {
      const attached = stage.attach(placement, hit, radius);
      settings.position = attached.position; settings.rotation = attached.rotation;
      geometryDirty = true; geometryFrame();
      post('placed', { ...attached, warning: stage.collision(placement, visibleBounds(placement)) });
    }
  } else if (settings.tool === 'tag') {
    post('shot', window.characterViewer.aimAt(coordinate.x, coordinate.y));
  } else if (['paint', 'erase'].includes(settings.tool)) {
    if (previousPointer) {
      const steps = Math.min(10, Math.max(1, Math.ceil(Math.hypot(coordinate.x - previousPointer.x, coordinate.y - previousPointer.y) * 40)));
      for (let step = 1; step <= steps; step++) paintPoint(THREE.MathUtils.lerp(previousPointer.x, coordinate.x, step / steps), THREE.MathUtils.lerp(previousPointer.y, coordinate.y, step / steps));
    } else paintPoint(coordinate.x, coordinate.y);
    previousPointer = coordinate;
  }
}

renderer.domElement.addEventListener('pointerdown', event => {
  pointers.add(event.pointerId); previousPointer = null;
  renderer.domElement.focus({ preventScroll: true });
  if (rig && ['paint', 'erase', 'sample'].includes(settings.tool)) { rig.finish(); geometryDirty = true; geometryFrame(); }
  if (settings.tool === 'tag') { aimDrag = { horizontal: event.clientX, vertical: event.clientY, moved: false }; return; }
  if (pointers.size === 1) pointerAction(event);
});
renderer.domElement.addEventListener('pointermove', event => {
  if (pointers.has(event.pointerId) && settings.tool === 'tag' && aimDrag) {
    const horizontal = event.clientX - aimDrag.horizontal, vertical = event.clientY - aimDrag.vertical;
    if (Math.hypot(horizontal, vertical) > 2) aimDrag.moved = true;
    const rotation = new THREE.Euler().setFromQuaternion(camera.quaternion, 'YXZ');
    rotation.y -= horizontal * 0.006;
    rotation.x = THREE.MathUtils.clamp(rotation.x - vertical * 0.006, -1.4, 1.4);
    camera.quaternion.setFromEuler(rotation);
    controls.target.copy(camera.position).add(camera.getWorldDirection(new THREE.Vector3()));
    aimDrag.horizontal = event.clientX; aimDrag.vertical = event.clientY;
  }
  if (pointers.has(event.pointerId) && ['paint', 'erase'].includes(settings.tool)) pointerAction(event);
});
const finishPointer = event => {
  if (event.type === 'pointerup' && settings.tool === 'tag' && aimDrag && !aimDrag.moved) pointerAction(event);
  aimDrag = null;
  pointers.delete(event.pointerId); previousPointer = null;
  if (painter?.end()) notifyPaint();
};
for (const name of ['pointerup', 'pointercancel', 'lostpointercapture']) renderer.domElement.addEventListener(name, finishPointer);

function validateGLB(buffer) {
  const view = new DataView(buffer);
  if (buffer.byteLength < 20 || view.getUint32(0, true) !== 0x46546c67 || view.getUint32(4, true) !== 2) throw new Error('Not a GLB 2.0 model.');
  if (view.getUint32(8, true) !== buffer.byteLength || view.getUint32(16, true) !== 0x4e4f534a) throw new Error('Invalid GLB container.');
  const length = view.getUint32(12, true);
  const json = JSON.parse(new TextDecoder().decode(new Uint8Array(buffer, 20, length)));
  for (const item of [...(json.images ?? []), ...(json.buffers ?? [])]) if (item.uri && !item.uri.startsWith('data:')) throw new Error('Only self-contained models are supported.');
}

async function decode(base64) {
  const bytes = Uint8Array.from(atob(base64), character => character.charCodeAt(0));
  validateGLB(bytes.buffer);
  const manager = new THREE.LoadingManager();
  manager.setURLModifier(url => {
    if (!url.startsWith('blob:') && !url.startsWith('data:')) throw new Error('External model resources are blocked.');
    return url;
  });
  return new GLTFLoader(manager).setMeshoptDecoder(MeshoptDecoder).parseAsync(bytes.buffer, '');
}

function base64(buffer) {
  const bytes = new Uint8Array(buffer);
  let encoded = '';
  for (let offset = 0; offset < bytes.length; offset += 32768) encoded += String.fromCharCode(...bytes.subarray(offset, offset + 32768));
  return btoa(encoded);
}

window.characterViewer = {
  async load(data, attribution, paint, savedScene) {
    try {
      const gltf = await decode(data);
      if (character) orientation.remove(character);
      if (skeleton) scene.remove(skeleton);
      character = gltf.scene;
      if (attribution) character.userData.sourceAttribution = attribution;
      orientation.add(character);
      rig = new HumanoidRig(character);
      const box = new THREE.Box3().setFromObject(character, true);
      const size = box.getSize(new THREE.Vector3());
      character.scale.multiplyScalar(1.75 / Math.max(size.y, 0.1));
      const center = box.getCenter(new THREE.Vector3());
      character.position.x -= center.x * character.scale.x;
      character.position.z -= center.z * character.scale.z;
      buildBodyForms(character, rig);
      painter = new SurfacePainter(character);
      await painter.restore(paint);
      skeleton = new THREE.SkeletonHelper(character);
      skeleton.visible = false; scene.add(skeleton);
      geometryDirty = true; geometryFrame(); setAppearance();
      if (savedScene?.clones) await this.restoreClones(savedScene.clones);
      fit(); status.textContent = '';
      post('loaded', rig.descriptors());
      post('capabilities', { humanoid: rig.canRetarget, poses: posePages, room: stage.data.name });
      notifyPaint();
    } catch (error) { status.textContent = 'Could not display this model.'; post('error', error.message); }
  },
  configure(next, nextAngles = {}, yaw = 0, showSkeleton = false, immediate = false) {
    if (!character) return;
    const previousTransform = JSON.stringify([settings.position, settings.rotation, settings.scale, settings.form]);
    settings = { ...settings, ...next };
    if (previousTransform !== JSON.stringify([settings.position, settings.rotation, settings.scale, settings.form])) { geometryDirty = true; pendingAssessment = true; }
    settings.scale = THREE.MathUtils.clamp(settings.scale, 0.5, 1.5);
    controls.enableRotate = settings.tool === 'orbit'; controls.enablePan = settings.tool === 'orbit';
    controls.enabled = settings.tool !== 'tag';
    placement.position.fromArray(settings.position); placement.quaternion.fromArray(settings.rotation).normalize(); placement.scale.setScalar(settings.scale);
    orientation.quaternion.setFromAxisAngle(new THREE.Vector3(0, 1, 0), THREE.MathUtils.degToRad(yaw));
    if (['prone', 'side', 'lean'].includes(settings.preset)) {
      const axis = (settings.preset === 'prone' ? rig.right : rig.forward).clone().applyQuaternion(character.quaternion);
      const angle = settings.preset === 'prone' ? -Math.PI / 2 : settings.preset === 'side' ? Math.PI / 2 : 0.25;
      orientation.quaternion.multiply(new THREE.Quaternion().setFromAxisAngle(axis, angle));
    }
    const serialized = JSON.stringify(nextAngles);
    if (settings.preset !== lastPose) {
      post('rig', rig.select(settings.preset, nextAngles, immediate)); lastPose = settings.preset; geometryDirty = true; pendingFit = true; pendingAssessment = true;
    } else if (serialized !== lastAngles) { rig.adjust(nextAngles, immediate); geometryDirty = true; pendingAssessment = true; }
    if (yaw !== lastYaw) { geometryDirty = true; pendingAssessment = true; }
    lastAngles = serialized; lastYaw = yaw;
    skeleton.visible = showSkeleton;
    setAppearance();
    if (immediate) { rig.finish(); geometryDirty = true; geometryFrame(); }
  },
  pose(nextAngles, yaw, showSkeleton) { this.configure({}, nextAngles, yaw, showSkeleton, true); },
  setRoom(data) { stage.setRoom(data); setAppearance(); post('room', stage.data.name); },
  roomGeometry() { return stage.data; },
  viewRay() { return { origin: camera.position.toArray(), direction: camera.getWorldDirection(new THREE.Vector3()).toArray(), fov: camera.fov, aspect: camera.aspect }; },
  beginHunt() {
    const spawn = stage.spawn();
    camera.position.copy(spawn.position); controls.target.copy(spawn.target);
    camera.lookAt(spawn.target); pendingFit = false;
  },
  aimAt(horizontal, vertical) {
    const hit = hitAt(horizontal, vertical, [placement, ...stage.clones, stage.others, ...(stage.visible ? stage.surfaces.filter(surface => surface.userData.kind !== 'window') : [])]);
    let targetID = null;
    for (let node = hit?.object; node; node = node.parent) if (node.userData.ownerID) { targetID = node.userData.ownerID; break; }
    return { origin: raycaster.ray.origin.toArray(), direction: raycaster.ray.direction.toArray(), targetID };
  },
  owner(id) { placement.userData.ownerID = id; stage.clones.forEach(clone => { clone.userData.ownerID = id; }); },
  resetCamera() { fit(settings.room); },
  paintAt(horizontal, vertical, options = {}) {
    const previous = { ...settings };
    settings = { ...settings, ...options, tool: options.erase ? 'erase' : 'paint' };
    rig.finish(); geometryDirty = true;
    const changed = paintPoint(horizontal, vertical);
    painter.end(); notifyPaint(); settings = previous;
    return changed;
  },
  action(name) {
    if (!painter) return;
    if (name === 'undo') painter.undo();
    if (name === 'redo') painter.undo(true);
    if (name === 'fill') painter.fill(settings.color);
    if (name === 'originalColor') painter.fill();
    if (name === 'white') painter.fill('#ffffff');
    if (name === 'clone') {
      rig.finish(); geometryDirty = true; geometryFrame();
      if (stage.addClone(placement)) cloneRecords.push({ transform: placement.matrix.toArray(), poseTransform: orientation.matrix.toArray(),
        sourceTransform: character.matrix.toArray(), bones: rig.bones.map(bone => bone.quaternion.toArray()), paint: painter.serialize(), settings: { ...settings }, yaw: lastYaw });
      else post('warning', 'Two clones are already placed. Clear them to make another.');
    }
    if (name === 'clearClones') { stage.clearClones(); cloneRecords = []; }
    if (name === 'detach') {
      settings.rotation = [0, 0, 0, 1]; settings.position[1] = 0;
      post('placed', { position: settings.position, rotation: settings.rotation, attached: null, warning: null });
    }
    if (name === 'inspect') fit();
    post('clones', stage.clones.length); notifyPaint();
  },
  async restoreClones(records) {
    stage.clearClones(); cloneRecords = [];
    for (const record of records.slice(0, 2)) {
      if (!stage.addClone(placement)) continue;
      const clone = stage.clones.at(-1);
      if (record.transform?.length === 16) new THREE.Matrix4().fromArray(record.transform).decompose(clone.position, clone.quaternion, clone.scale);
      const poseRoot = clone.children[0], sourceRoot = poseRoot?.children[0];
      if (poseRoot && record.poseTransform?.length === 16) new THREE.Matrix4().fromArray(record.poseTransform).decompose(poseRoot.position, poseRoot.quaternion, poseRoot.scale);
      if (sourceRoot && record.sourceTransform?.length === 16) new THREE.Matrix4().fromArray(record.sourceTransform).decompose(sourceRoot.position, sourceRoot.quaternion, sourceRoot.scale);
      clone.traverse(node => { if (node.isMesh) node.visible = (node.userData.form ?? 'person') === (record.settings?.form ?? 'person'); });
      const cloneRig = new HumanoidRig(clone);
      cloneRig.bones.forEach((bone, index) => { if (record.bones?.[index]?.length === 4) bone.quaternion.fromArray(record.bones[index]).normalize(); });
      await new SurfacePainter(clone).restore(record.paint);
      cloneRecords.push(record);
    }
    post('clones', cloneRecords.length);
  },
  walk(horizontal, forward) {
    const direction = camera.getWorldDirection(new THREE.Vector3()); direction.y = 0; direction.normalize();
    const right = new THREE.Vector3().crossVectors(direction, camera.up).normalize();
    const delta = direction.multiplyScalar(forward * 0.25).addScaledVector(right, horizontal * 0.25);
    const candidate = camera.position.clone().add(delta);
    const collision = new THREE.Raycaster(camera.position, delta.clone().normalize(), 0, delta.length() + 0.15);
    if (collision.intersectObjects(stage.surfaces.filter(surface => !['floor', 'decoration'].includes(surface.userData.kind)), false).length) return false;
    camera.position.copy(candidate); controls.target.add(delta); controls.update(); return true;
  },
  async remote(id, data) {
    const previous = remoteGroups.get(id); if (previous) stage.others.remove(previous);
    const gltf = await decode(data);
    gltf.scene.traverse(node => { delete node.userData.ownerID; });
    gltf.scene.userData.ownerID = id;
    stage.others.add(gltf.scene); remoteGroups.set(id, gltf.scene);
  },
  visibility(ids, showOwn = true) {
    placement.visible = showOwn; stage.clones.forEach(clone => { clone.visible = showOwn; });
    for (const [id, group] of remoteGroups) group.visible = ids.includes(id);
  },
  practiceTag(origin, direction) {
    if (!placement.visible) return false;
    const ray = new THREE.Raycaster(new THREE.Vector3().fromArray(origin), new THREE.Vector3().fromArray(direction).normalize());
    const hit = ray.intersectObjects([placement, ...stage.clones], true).find(hit => visible(hit.object));
    const obstruction = stage.visible ? ray.intersectObjects(stage.surfaces.filter(surface => surface.userData.kind !== 'window'), false)[0] : null;
    if (!hit || (obstruction && obstruction.distance < hit.distance)) return false;
    placement.visible = false; stage.clones.forEach(clone => { clone.visible = false; });
    return true;
  },
  diagnostics() {
    rig.finish(); geometryDirty = true; geometryFrame();
    if (pendingFit) { fit(false, true); pendingFit = false; }
    const box = visibleBounds(placement);
    const cloneBounds = stage.clones.map(clone => { const bounds = visibleBounds(clone); return { min: bounds.min.toArray(), max: bounds.max.toArray() }; });
    return { ...rig.report(), quality: rig.surfaceQuality(), bounds: { min: box.min.toArray(), max: box.max.toArray() }, paint: painter.checksum(), history: painter.history(), clones: stage.clones.length, cloneBounds, remoteOwners: [...remoteGroups.keys()], collision: stage.collision(placement, box) };
  },
  screenshot() { renderer.render(scene, camera); return renderer.domElement.toDataURL('image/png').split(',')[1]; },
  async exportModel() {
    try {
      if (!character) throw new Error('Load a model first.');
      rig.finish(); geometryDirty = true; geometryFrame(); painter.end(); renderer.render(scene, camera);
      const thumbnail = renderer.domElement.toDataURL('image/png').split(',')[1];
      const root = new THREE.Group(); root.name = 'Mecha Soonelians disguise'; root.add(cloneSkeleton(placement));
      stage.clones.forEach(clone => root.add(cloneSkeleton(clone)));
      root.children.forEach(child => { child.visible = true; });
      root.updateMatrixWorld(true);
      const hidden = [];
      root.traverse(node => { if (node.isMesh && !node.visible) hidden.push(node); });
      for (const mesh of hidden) {
        const parent = mesh.parent;
        [...mesh.children].forEach(child => parent.attach(child));
        parent.remove(mesh);
      }
      const boxes = [placement, ...stage.clones].map((group, index) => {
        const box = visibleBounds(group);
        return { id: String(index), min: box.min.toArray(), max: box.max.toArray() };
      });
      root.userData.disguises = boxes;
      const result = await new GLTFExporter().parseAsync(root, { binary: true, onlyVisible: true, trs: true });
      post('exported', { model: base64(result), thumbnail, paint: painter.serialize(), scene: { version: 1, clones: cloneRecords }, boxes });
    } catch (error) { post('error', error.message); }
  }
};

window.addEventListener('keydown', event => {
  const key = event.key.toLowerCase();
  if (['w', 'a', 's', 'd'].includes(key)) window.characterViewer.walk(key === 'd' ? 1 : key === 'a' ? -1 : 0, key === 'w' ? 1 : key === 's' ? -1 : 0);
  if (key === 'q') window.characterViewer.action('clone');
  if (key === 'x') window.characterViewer.action('clearClones');
  if (key === 'r' && !event.repeat) post('wheel', true);
  if (key === 'f' && !event.repeat) post('tool', settings.tool === 'paint' ? 'orbit' : 'paint');
  if (key === ' ' && !event.repeat) post('tool', settings.tool === 'paint' ? 'sample' : 'attach');
  if (key === '1') post('taunt', true);
});
window.addEventListener('keyup', event => { if (event.key.toLowerCase() === 'r') post('wheel', false); });
new ResizeObserver(() => {
  const width = document.documentElement.clientWidth, height = document.documentElement.clientHeight;
  renderer.setSize(width, height); camera.aspect = width / height; camera.updateProjectionMatrix();
}).observe(document.body);
renderer.setAnimationLoop(time => {
  const moving = rig?.tick(time);
  if (moving) geometryDirty = true;
  geometryFrame();
  if (!moving && pendingFit) { if (settings.tool !== 'tag') fit(false, true); pendingFit = false; }
  if (!moving && pendingAssessment) {
    pendingAssessment = false;
    post('warning', stage.collision(placement, visibleBounds(placement)) ?? (settings.form === 'person' ? rig.surfaceQuality().warning : null));
  }
  if (controls.enabled) controls.update(); renderer.render(scene, camera);
});
post('ready', true);
