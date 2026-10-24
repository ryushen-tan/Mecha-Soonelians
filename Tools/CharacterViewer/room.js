import * as THREE from 'three';
import { clone as cloneSkeleton } from 'three/addons/utils/SkeletonUtils.js';

export const practiceRoom = {
  name: 'Practice room', source: 'practice', surfaces: [
    { id: 'floor', kind: 'floor', dimensions: [6, 0.08, 6], position: [0, -0.06, 0], color: '#bbac8e' },
    { id: 'back-wall', kind: 'wall', dimensions: [6, 3, 0.12], position: [0, 1.5, 2.8], color: '#d2d7c0' },
    { id: 'left-wall', kind: 'wall', dimensions: [0.12, 3, 6], position: [-3, 1.5, 0], color: '#b8c8ca' },
    { id: 'cabinet', kind: 'object', dimensions: [1.2, 0.85, 0.6], position: [1.5, 0.425, 2.35], color: '#718474' },
    { id: 'sofa', kind: 'object', dimensions: [1.8, 0.65, 0.8], position: [-2.25, 0.325, 1.6], color: '#a78f80' },
    { id: 'rug', kind: 'decoration', dimensions: [2.8, 0.015, 2], position: [0, 0, 0.3], color: '#d3c69f' }
  ]
};

export class RoomStage {
  constructor(scene) {
    this.scene = scene;
    this.room = new THREE.Group();
    this.room.name = 'Room geometry';
    scene.add(this.room);
    this.surfaces = [];
    this.clones = [];
    this.others = new THREE.Group();
    scene.add(this.others);
    this.visible = false;
    this.setRoom(practiceRoom);
  }

  setRoom(data) {
    this.surfaces.forEach(surface => { surface.geometry.dispose(); surface.material.dispose(); });
    this.room.clear();
    this.surfaces = [];
    this.data = data?.surfaces?.length ? data : practiceRoom;
    for (const surface of this.data.surfaces.slice(0, 1500)) {
      if (!surface.dimensions?.every(Number.isFinite)) continue;
      const dimensions = surface.dimensions.map(value => Math.max(0.035, Math.min(Math.abs(value), 100)));
      const material = new THREE.MeshStandardMaterial({ color: surface.color ?? '#c3c9b6', roughness: 0.85,
        transparent: surface.kind === 'window', opacity: surface.kind === 'window' ? 0.2 : 1 });
      let geometry = new THREE.BoxGeometry(...dimensions);
      if (surface.holes?.length) {
        const [width, height, depth] = dimensions;
        const shape = new THREE.Shape();
        shape.moveTo(-width / 2, -height / 2); shape.lineTo(width / 2, -height / 2);
        shape.lineTo(width / 2, height / 2); shape.lineTo(-width / 2, height / 2); shape.closePath();
        for (const [horizontal, vertical, holeWidth, holeHeight] of surface.holes) {
          const hole = new THREE.Path();
          hole.moveTo(horizontal - holeWidth / 2, vertical - holeHeight / 2);
          hole.lineTo(horizontal - holeWidth / 2, vertical + holeHeight / 2);
          hole.lineTo(horizontal + holeWidth / 2, vertical + holeHeight / 2);
          hole.lineTo(horizontal + holeWidth / 2, vertical - holeHeight / 2); hole.closePath(); shape.holes.push(hole);
        }
        geometry = new THREE.ExtrudeGeometry(shape, { depth, bevelEnabled: false });
        geometry.translate(0, 0, -depth / 2);
      }
      const mesh = new THREE.Mesh(geometry, material);
      if (surface.transform?.length === 16 && surface.transform.every(Number.isFinite)) {
        mesh.applyMatrix4(new THREE.Matrix4().fromArray(surface.transform));
      } else mesh.position.fromArray(surface.position ?? [0, 0, 0]);
      mesh.name = surface.id;
      mesh.userData.kind = surface.kind;
      mesh.userData.holes = surface.holes ?? [];
      mesh.receiveShadow = true;
      this.room.add(mesh);
      this.surfaces.push(mesh);
    }
    this.room.visible = this.visible;
    this.room.updateMatrixWorld(true);
  }

  show(value) { this.visible = value; this.room.visible = value; }

  paintWall(group, bounds, preferredID) {
    group.updateMatrixWorld(true);
    this.room.updateMatrixWorld(true);
    const body = bounds ?? new THREE.Box3().setFromObject(group);
    const center = body.getCenter(new THREE.Vector3());
    const feet = center.clone().setY(body.min.y);
    const height = body.max.y - body.min.y;
    let nearest = null, distance = Infinity;
    for (const wall of this.surfaces.filter(surface => surface.userData.kind === 'wall' && (!preferredID || surface.name === preferredID))) {
      wall.geometry.computeBoundingBox();
      const box = wall.geometry.boundingBox;
      const size = box.getSize(new THREE.Vector3()).toArray();
      const thin = size.indexOf(Math.min(...size));
      const axes = [0, 1, 2].filter(axis => axis !== thin);
      const vertical = axes.reduce((first, second) => Math.abs(wall.matrixWorld.elements[first * 4 + 1]) > Math.abs(wall.matrixWorld.elements[second * 4 + 1]) ? first : second);
      const horizontal = axes.find(axis => axis !== vertical);
      const up = wall.matrixWorld.elements[vertical * 4 + 1];
      if (Math.abs(up) < 0.7) continue;
      const inverse = wall.matrixWorld.clone().invert();
      const local = feet.clone().applyMatrix4(inverse);
      const sign = center.clone().applyMatrix4(inverse).getComponent(thin) >= box.getCenter(new THREE.Vector3()).getComponent(thin) ? 1 : -1;
      const normal = new THREE.Vector3().setComponent(thin, sign);
      const worldNormal = normal.clone().applyNormalMatrix(new THREE.Matrix3().getNormalMatrix(wall.matrixWorld)).normalize();
      const minimum = box.min.getComponent(vertical) + 0.006 + (up < 0 ? height / Math.abs(up) : 0);
      const maximum = box.max.getComponent(vertical) - 0.006 - (up > 0 ? height / Math.abs(up) : 0);
      if (maximum < minimum) continue;
      local.setComponent(vertical, THREE.MathUtils.clamp(local.getComponent(vertical), minimum, maximum));
      local.setComponent(thin, (sign > 0 ? box.max : box.min).getComponent(thin));
      const lower = box.min.getComponent(horizontal) + 0.15, upper = box.max.getComponent(horizontal) - 0.15;
      if (upper < lower) continue;
      const candidates = [THREE.MathUtils.clamp(local.getComponent(horizontal), lower, upper), (lower + upper) / 2,
        THREE.MathUtils.lerp(lower, upper, 0.25), THREE.MathUtils.lerp(lower, upper, 0.75)];
      for (const candidate of candidates) {
        const point = local.clone().setComponent(horizontal, candidate).applyMatrix4(wall.matrixWorld);
        const solid = [0.2, 0.5, 0.8].every(fraction => {
          const origin = point.clone().addScaledVector(worldNormal, 0.2).add(new THREE.Vector3(0, height * fraction, 0));
          return new THREE.Raycaster(origin, worldNormal.clone().negate(), 0, 0.5).intersectObject(wall, false).length > 0;
        });
        const score = point.distanceToSquared(feet);
        if (solid && score < distance) { distance = score; nearest = { point, face: { normal }, object: wall, worldNormal }; }
      }
    }
    return nearest;
  }

  spawn() {
    this.room.updateMatrixWorld(true);
    for (const floor of this.surfaces.filter(surface => surface.userData.kind === 'floor')) {
      const bounds = new THREE.Box3().setFromObject(floor);
      for (const horizontal of [0.25, 0.75, 0.5]) for (const depth of [0.25, 0.75, 0.5]) {
        const point = new THREE.Vector3(THREE.MathUtils.lerp(bounds.min.x, bounds.max.x, horizontal), bounds.max.y + 1.6,
          THREE.MathUtils.lerp(bounds.min.z, bounds.max.z, depth));
        if (!this.surfaces.some(surface => !['floor', 'decoration'].includes(surface.userData.kind) && new THREE.Box3().setFromObject(surface).expandByScalar(0.2).containsPoint(point))) {
          return { position: point, target: bounds.getCenter(new THREE.Vector3()).setY(point.y - 0.15) };
        }
      }
    }
    return { position: new THREE.Vector3(0, 1.6, -2), target: new THREE.Vector3(0, 1.4, 0) };
  }

  addClone(group) {
    if (this.clones.length >= 2) return false;
    const clone = cloneSkeleton(group);
    clone.traverse(node => {
      if (!node.isMesh) return;
      const materials = Array.isArray(node.material) ? node.material : [node.material];
      const copied = materials.map(material => {
        const copy = material.clone();
        if (material.map?.image) {
          const canvas = document.createElement('canvas');
          canvas.width = material.map.image.width;
          canvas.height = material.map.image.height;
          canvas.getContext('2d').drawImage(material.map.image, 0, 0);
          copy.map = material.map.clone();
          copy.map.image = canvas;
          copy.map.needsUpdate = true;
        }
        return copy;
      });
      node.material = Array.isArray(node.material) ? copied : copied[0];
      node.userData.clone = true;
    });
    clone.name = `Clone ${this.clones.length + 1}`;
    this.scene.add(clone);
    this.clones.push(clone);
    return true;
  }

  clearClones() {
    this.clones.forEach(clone => this.scene.remove(clone));
    this.clones = [];
  }

  attach(group, hit, forward = new THREE.Vector3(0, 0, -1)) {
    const normal = hit.face.normal.clone().applyNormalMatrix(new THREE.Matrix3().getNormalMatrix(hit.object.matrixWorld)).normalize();
    const up = Math.abs(normal.y) > 0.9 ? new THREE.Vector3(0, 0, -1) : new THREE.Vector3(0, 1, 0);
    const back = normal.clone().negate();
    const right = new THREE.Vector3().crossVectors(up, back).normalize();
    up.crossVectors(back, right).normalize();
    if (hit.object.userData.kind === 'floor') group.quaternion.identity();
    else group.quaternion.setFromRotationMatrix(new THREE.Matrix4().makeBasis(right, up, back))
      .multiply(new THREE.Quaternion().setFromUnitVectors(forward.clone().setY(0).normalize(), new THREE.Vector3(0, 0, -1)));
    group.position.copy(hit.point);
    group.updateMatrixWorld(true);
    let minimum = Infinity;
    const vertex = new THREE.Vector3();
    group.traverse(mesh => {
      if (!mesh.isMesh || !mesh.visible) return;
      if (mesh.isSkinnedMesh) mesh.skeleton.update();
      for (let index = 0; index < mesh.geometry.attributes.position.count; index++) {
        mesh.getVertexPosition(index, vertex).applyMatrix4(mesh.matrixWorld).sub(hit.point);
        minimum = Math.min(minimum, vertex.dot(normal));
      }
    });
    group.position.addScaledVector(normal, Number.isFinite(minimum) ? -minimum + 0.006 : 0.006);
    return { position: group.position.toArray(), rotation: group.quaternion.toArray(), attached: hit.object.name };
  }

  collision(group, actualBounds) {
    if (!this.visible) return null;
    const bounds = actualBounds ?? new THREE.Box3().setFromObject(group);
    for (const surface of this.surfaces) {
      if (['floor', 'decoration'].includes(surface.userData.kind)) continue;
      const overlap = bounds.clone().intersect(new THREE.Box3().setFromObject(surface));
      if (overlap.isEmpty()) continue;
      const size = overlap.getSize(new THREE.Vector3());
      if (Math.min(size.x, size.y, size.z) > 0.055) return 'Character overlaps ' + surface.name + '. Nudge it away from the surface.';
    }
    return null;
  }
}
