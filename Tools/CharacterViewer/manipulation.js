import * as THREE from 'three';
import { TransformControls } from 'three/addons/controls/TransformControls.js';

export function dragPosition(start, pointer, camera, normal) {
  camera.updateMatrixWorld(true);
  const plane = new THREE.Plane().setFromNormalAndCoplanarPoint(normal, start.hit);
  const ray = new THREE.Raycaster();
  ray.setFromCamera(pointer, camera);
  const point = ray.ray.intersectPlane(plane, new THREE.Vector3());
  if (Math.abs(ray.ray.direction.dot(normal)) > 0.2 && point && point.distanceTo(start.hit) < 20) {
    return start.position.clone().add(point.sub(start.hit));
  }
  if (Math.abs(normal.y) < 0.1) {
    const facing = new THREE.Plane().setFromNormalAndCoplanarPoint(camera.getWorldDirection(new THREE.Vector3()), start.hit);
    const projected = ray.ray.intersectPlane(facing, new THREE.Vector3());
    if (projected) return start.position.clone().add(projected.sub(start.hit));
  }
  const right = new THREE.Vector3(1, 0, 0).applyQuaternion(camera.quaternion).projectOnPlane(normal);
  if (right.lengthSq() < 0.01) right.crossVectors(new THREE.Vector3(0, 1, 0), normal);
  right.normalize();
  const up = new THREE.Vector3().crossVectors(normal, right).normalize();
  const preferred = new THREE.Vector3(0, 1, 0).applyQuaternion(camera.quaternion).projectOnPlane(normal);
  if (preferred.lengthSq() < 0.04) preferred.copy(camera.getWorldDirection(new THREE.Vector3())).projectOnPlane(normal);
  if (up.dot(preferred) < 0) up.negate();
  const distance = camera.position.distanceTo(start.hit) * Math.tan(THREE.MathUtils.degToRad(camera.fov) / 2);
  return start.position.clone().addScaledVector(right, (pointer.x - start.pointer.x) * distance * camera.aspect)
    .addScaledVector(up, (pointer.y - start.pointer.y) * distance);
}

export function transformPlacement(group, constraint, target, mode) {
  const position = group.position.clone(), rotation = group.quaternion.clone(), scale = group.scale.x;
  if (mode === 'translate') constraint.translate(group, target.position);
  else {
    if (![...target.position.toArray(), ...target.rotation.toArray(), target.scale].every(Number.isFinite)) return false;
    const size = THREE.MathUtils.clamp(target.scale, 0.15, 1.5);
    const steps = Math.max(1, Math.ceil(rotation.angleTo(target.rotation) / 0.04), Math.ceil(Math.abs(size - scale) / 0.025));
    let safe = { position: position.clone(), rotation: rotation.clone(), scale };
    for (let index = 1; index <= steps; index++) {
      const fraction = index / steps;
      group.position.lerpVectors(position, target.position, fraction);
      group.quaternion.slerpQuaternions(rotation, target.rotation, fraction).normalize();
      group.scale.setScalar(THREE.MathUtils.lerp(scale, size, fraction));
      if (!constraint.repair(group)) {
        group.position.copy(safe.position); group.quaternion.copy(safe.rotation); group.scale.setScalar(safe.scale);
        break;
      }
      safe = { position: group.position.clone(), rotation: group.quaternion.clone(), scale: group.scale.x };
    }
  }
  group.updateMatrixWorld(true);
  return group.position.distanceToSquared(position) > 1e-12 || group.quaternion.angleTo(rotation) > 1e-6 || Math.abs(group.scale.x - scale) > 1e-6;
}

export class ObjectManipulator {
  constructor(scene, camera, group, constraint, callbacks) {
    this.camera = camera; this.group = group; this.constraint = constraint; this.callbacks = callbacks;
    this.proxy = new THREE.Object3D(); scene.add(this.proxy);
    this.control = new TransformControls(camera);
    this.control.setSpace('world'); this.control.setSize(0.85);
    this.helper = this.control.getHelper(); scene.add(this.helper);
    this.outline = new THREE.Box3Helper(new THREE.Box3(), '#d4ed5e');
    this.outline.material.depthTest = false; this.outline.material.transparent = true; this.outline.material.opacity = 0.65;
    this.outline.renderOrder = 1000; scene.add(this.outline);
    this.selected = false; this.enabled = false; this.mode = 'translate'; this.gesture = null;
    this.control.addEventListener('objectChange', () => this.applyProxy());
    this.update();
  }

  configure(enabled, mode = 'translate') {
    if (!['translate', 'rotate', 'scale'].includes(mode)) mode = 'translate';
    if (this.gesture && (!enabled || mode !== this.mode)) this.end();
    const changed = mode !== this.mode;
    this.enabled = enabled; this.mode = mode; this.control.setMode(mode);
    if (!enabled) this.select(false);
    else if (changed) this.select(true);
    this.update();
  }

  select(value) {
    value = Boolean(value && this.enabled);
    if (this.selected !== value) { this.selected = value; this.callbacks.selection(value); }
    if (value && !this.control.object) this.control.attach(this.proxy);
    if (!value) this.control.detach();
    this.update();
  }

  update() {
    this.helper.visible = this.outline.visible = this.enabled && this.selected;
    if (!this.helper.visible || this.constraint.localBounds.isEmpty()) return;
    const bounds = this.constraint.body(this.group).bounds;
    this.outline.box.copy(bounds);
    if (!this.gesture || this.gesture.kind === 'body') {
      this.proxy.position.copy(bounds.getCenter(new THREE.Vector3()));
      this.proxy.quaternion.copy(this.group.quaternion); this.proxy.scale.setScalar(this.group.scale.x);
    }
    this.proxy.updateMatrixWorld(true); this.helper.updateMatrixWorld(true);
  }

  begin(pointer, hit) {
    if (!this.enabled || this.gesture) return false;
    this.update();
    this.control.pointerHover(pointer);
    const handle = this.selected && this.control.axis && !(hit && this.mode === 'translate');
    if (!hit && !handle) return false;
    this.select(true);
    this.gesture = { kind: handle ? 'gizmo' : 'body', pointer: new THREE.Vector2(pointer.x, pointer.y),
      position: this.group.position.clone(), rotation: this.group.quaternion.clone(), scale: this.group.scale.x,
      center: this.proxy.position.clone(), hit: hit?.point.clone() ?? this.proxy.position.clone(), changed: false,
      support: this.constraint.support, normal: this.constraint.normal(this.constraint.support) };
    if (handle) { this.helper.updateMatrixWorld(true); this.control.pointerDown({ ...pointer, button: 0 }); }
    return true;
  }

  move(pointer) {
    const start = this.gesture;
    if (!start) return;
    if (start.kind === 'gizmo') { this.control.pointerMove({ ...pointer, button: -1 }); return; }
    let target = { position: start.position.clone(), rotation: start.rotation.clone(), scale: start.scale };
    if (this.mode === 'translate') target.position = dragPosition(start, pointer, this.camera, start.normal);
    else if (this.mode === 'rotate') {
      const up = new THREE.Vector3(0, 1, 0).applyQuaternion(this.camera.quaternion);
      const right = new THREE.Vector3(1, 0, 0).applyQuaternion(this.camera.quaternion);
      target.rotation.premultiply(new THREE.Quaternion().setFromAxisAngle(up, (pointer.x - start.pointer.x) * Math.PI));
      target.rotation.premultiply(new THREE.Quaternion().setFromAxisAngle(right, -(pointer.y - start.pointer.y) * Math.PI));
      const delta = target.rotation.clone().multiply(start.rotation.clone().invert());
      target.position.copy(start.position).sub(start.center).applyQuaternion(delta).add(start.center);
    } else {
      target.scale = THREE.MathUtils.clamp(start.scale * Math.exp((pointer.y - start.pointer.y) * 1.5), 0.15, 1.5);
      target.position.copy(start.position).sub(start.center).multiplyScalar(target.scale / start.scale).add(start.center);
    }
    this.apply(target);
  }

  applyProxy() {
    const start = this.gesture;
    if (!start || start.kind !== 'gizmo') return;
    const target = { position: start.position.clone().add(this.proxy.position).sub(start.center),
      rotation: this.proxy.quaternion.clone(), scale: start.scale };
    if (this.mode === 'scale') {
      const ratios = this.proxy.scale.toArray().map(value => value / start.scale);
      const ratio = ratios.sort((first, second) => Math.abs(second - 1) - Math.abs(first - 1))[0];
      target.scale = THREE.MathUtils.clamp(start.scale * Math.max(0.01, ratio), 0.15, 1.5);
      target.position.copy(start.position).sub(start.center).multiplyScalar(target.scale / start.scale).add(start.center);
    } else if (this.mode === 'rotate') {
      const delta = target.rotation.clone().multiply(start.rotation.clone().invert());
      target.position.copy(start.position).sub(start.center).applyQuaternion(delta).add(start.center);
    }
    this.apply(target);
  }

  apply(target) {
    if (transformPlacement(this.group, this.constraint, target, this.mode)) {
      this.gesture.changed = true; this.callbacks.change(); this.update();
    }
  }

  end(cancel = false) {
    const start = this.gesture;
    if (!start) return;
    this.control.pointerUp({ button: 0 });
    if (cancel && start.changed) {
      this.constraint.support = start.support;
      this.group.position.copy(start.position); this.group.quaternion.copy(start.rotation); this.group.scale.setScalar(start.scale);
      this.group.updateMatrixWorld(true); this.callbacks.change();
    }
    this.gesture = null; this.update(); this.callbacks.end(start.changed);
  }

  report() {
    this.update();
    const center = this.constraint.localBounds.isEmpty() ? new THREE.Vector3() : this.constraint.body(this.group).bounds.getCenter(new THREE.Vector3());
    const handles = { X: [], Y: [], Z: [] };
    if (this.enabled && this.selected) this.helper.traverse(mesh => {
      if (!mesh.isMesh || !handles[mesh.name]) return;
      for (let node = mesh; node; node = node.parent) if (!node.visible) return;
      const positions = mesh.geometry.attributes.position;
      const step = Math.max(1, Math.floor(positions.count / 12));
      for (let index = 0; index < positions.count && handles[mesh.name].length < 24; index += step) {
        handles[mesh.name].push(new THREE.Vector3().fromBufferAttribute(positions, index).applyMatrix4(mesh.matrixWorld).project(this.camera).toArray());
      }
    });
    return { selected: this.selected, mode: this.mode, dragging: Boolean(this.gesture),
      axis: this.control.axis, handles, center: center.project(this.camera).toArray(), axes: this.enabled && this.selected ? ['X', 'Y', 'Z'] : [] };
  }
}
