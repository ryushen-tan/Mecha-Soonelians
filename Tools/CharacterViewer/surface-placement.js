import * as THREE from 'three';
import { OBB } from 'three/addons/math/OBB.js';

const clearance = 0.006;
const axes = [0, 1, 2];

function worldBox(bounds, matrix) {
  const box = new OBB().fromBox3(bounds).applyMatrix4(matrix);
  box.center.copy(bounds.getCenter(new THREE.Vector3()).applyMatrix4(matrix));
  box.halfSize.set(Math.abs(box.halfSize.x), Math.abs(box.halfSize.y), Math.abs(box.halfSize.z));
  return box;
}

function boxCorners(box) {
  const points = [];
  for (const horizontal of [box.min.x, box.max.x]) for (const vertical of [box.min.y, box.max.y])
    for (const depth of [box.min.z, box.max.z]) points.push(new THREE.Vector3(horizontal, vertical, depth));
  return points;
}

function solidBoxes(mesh, bounds) {
  const holes = mesh.userData.holes ?? [];
  if (!holes.length) return [bounds];
  const divisions = axis => [...new Set([bounds.min.getComponent(axis), bounds.max.getComponent(axis),
    ...holes.flatMap(hole => [hole[axis] - hole[axis + 2] / 2, hole[axis] + hole[axis + 2] / 2])]
    .map(value => THREE.MathUtils.clamp(value, bounds.min.getComponent(axis), bounds.max.getComponent(axis))))].sort((first, second) => first - second);
  const horizontal = divisions(0), vertical = divisions(1), boxes = [];
  for (let column = 1; column < horizontal.length; column++) for (let row = 1; row < vertical.length; row++) {
    const centerX = (horizontal[column - 1] + horizontal[column]) / 2;
    const centerY = (vertical[row - 1] + vertical[row]) / 2;
    if (holes.some(([left, bottom, width, height]) => Math.abs(centerX - left) < width / 2 && Math.abs(centerY - bottom) < height / 2)) continue;
    boxes.push(new THREE.Box3(new THREE.Vector3(horizontal[column - 1], vertical[row - 1], bounds.min.z),
      new THREE.Vector3(horizontal[column], vertical[row], bounds.max.z)));
  }
  return boxes;
}

export class SurfacePlacement {
  constructor(stage) {
    this.stage = stage;
    this.localBounds = new THREE.Box3();
    this.support = null;
    this.meshes = null;
  }

  refresh(group) {
    if (this.meshes !== this.stage.surfaces) {
      this.meshes = this.stage.surfaces;
      this.stage.room.updateMatrixWorld(true);
      this.surfaces = this.meshes.filter(mesh => mesh.userData.kind !== 'decoration').map(mesh => {
        mesh.geometry.computeBoundingBox();
        const bounds = mesh.geometry.boundingBox.clone();
        return { mesh, bounds, inverse: mesh.matrixWorld.clone().invert(),
          worldBounds: bounds.clone().applyMatrix4(mesh.matrixWorld),
          solids: solidBoxes(mesh, bounds).map(box => worldBox(box, mesh.matrixWorld)) };
      });
      this.support = null;
    }
    group.updateMatrixWorld(true);
    const inverse = group.matrixWorld.clone().invert(), vertex = new THREE.Vector3();
    this.localBounds.makeEmpty();
    group.traverse(mesh => {
      if (!mesh.isMesh) return;
      for (let node = mesh; node && node !== group; node = node.parent) if (!node.visible) return;
      if (mesh.isSkinnedMesh) mesh.skeleton.update();
      for (let index = 0; index < mesh.geometry.attributes.position.count; index++) {
        mesh.getVertexPosition(index, vertex).applyMatrix4(mesh.matrixWorld).applyMatrix4(inverse);
        this.localBounds.expandByPoint(vertex);
      }
    });
    this.points = boxCorners(this.localBounds);
  }

  body(group) {
    group.updateMatrixWorld(true);
    return { box: worldBox(this.localBounds, group.matrixWorld),
      bounds: this.localBounds.clone().applyMatrix4(group.matrixWorld) };
  }

  obstruction(group) {
    const body = this.body(group);
    return this.surfaces.find(surface => surface.worldBounds.intersectsBox(body.bounds)
      && surface.solids.some(solid => solid.intersectsOBB(body.box, 1e-8)))?.mesh.name ?? null;
  }

  normal(face) {
    return new THREE.Vector3().setComponent(face.axis, face.sign)
      .applyNormalMatrix(new THREE.Matrix3().getNormalMatrix(face.surface.mesh.matrixWorld)).normalize();
  }

  faces(floorOnly = false) {
    return this.surfaces.flatMap(surface => axes.flatMap(axis => [-1, 1].map(sign => ({ surface, axis, sign }))))
      .filter(face => {
        const normal = this.normal(face);
        if (floorOnly && face.surface.mesh.userData.kind !== 'floor') return false;
        if (floorOnly || face.surface.mesh.userData.kind === 'floor') return normal.y > 0.99;
        return normal.y > 0.99 || Math.abs(normal.y) < 0.1;
      });
  }

  snap(group, face, clamp = false) {
    const { surface, axis, sign } = face;
    const normal = this.normal(face);
    const edge = (sign > 0 ? surface.bounds.max : surface.bounds.min).getComponent(axis);
    const plane = surface.bounds.getCenter(new THREE.Vector3()).setComponent(axis, edge).applyMatrix4(surface.mesh.matrixWorld);
    group.updateMatrixWorld(true);
    const minimum = Math.min(...this.points.map(point => point.clone().applyMatrix4(group.matrixWorld).sub(plane).dot(normal)));
    group.position.addScaledVector(normal, clearance - minimum);
    group.updateMatrixWorld(true);
    let projected = new THREE.Box3().setFromPoints(this.points.map(point => point.clone().applyMatrix4(group.matrixWorld).applyMatrix4(surface.inverse)));
    if (clamp) {
      const offset = new THREE.Vector3();
      for (const tangent of axes.filter(value => value !== axis)) {
        const lower = surface.bounds.min.getComponent(tangent) + clearance, upper = surface.bounds.max.getComponent(tangent) - clearance;
        if (projected.max.getComponent(tangent) - projected.min.getComponent(tangent) > upper - lower) return false;
        offset.setComponent(tangent, Math.max(0, lower - projected.min.getComponent(tangent)) + Math.min(0, upper - projected.max.getComponent(tangent)));
      }
      const origin = new THREE.Vector3().applyMatrix4(surface.mesh.matrixWorld);
      group.position.add(offset.applyMatrix4(surface.mesh.matrixWorld).sub(origin));
      group.updateMatrixWorld(true);
      projected = new THREE.Box3().setFromPoints(this.points.map(point => point.clone().applyMatrix4(group.matrixWorld).applyMatrix4(surface.inverse)));
    }
    for (const tangent of axes.filter(value => value !== axis)) {
      if (projected.min.getComponent(tangent) < surface.bounds.min.getComponent(tangent) + clearance - 1e-6
        || projected.max.getComponent(tangent) > surface.bounds.max.getComponent(tangent) - clearance + 1e-6) return false;
    }
    if (axis === 2 && (surface.mesh.userData.holes ?? []).some(([horizontal, vertical, width, height]) =>
      projected.max.x > horizontal - width / 2 && projected.min.x < horizontal + width / 2
      && projected.max.y > vertical - height / 2 && projected.min.y < vertical + height / 2)) return false;
    const contact = projected.getCenter(new THREE.Vector3()).setComponent(axis, edge).applyMatrix4(surface.mesh.matrixWorld);
    const hit = new THREE.Raycaster(contact.clone().addScaledVector(normal, 0.05), normal.clone().negate(), 0, 0.1)
      .intersectObject(surface.mesh, false)[0];
    return Boolean(hit && hit.point.distanceTo(contact) < 0.001 && !this.obstruction(group));
  }

  repair(group, floorOnly = false) {
    if (this.localBounds.isEmpty()) return false;
    const start = group.position.clone();
    if (!floorOnly && this.support) {
      const valid = this.snap(group, this.support, true);
      if (!valid) { group.position.copy(start); group.updateMatrixWorld(true); }
      return valid;
    }
    group.position.copy(start);
    const center = this.body(group).bounds.getCenter(new THREE.Vector3());
    const faces = this.faces(floorOnly).filter(face => {
      if (face.surface.mesh.userData.kind !== 'wall') return true;
      const local = center.clone().applyMatrix4(face.surface.inverse);
      const midpoint = face.surface.bounds.getCenter(new THREE.Vector3()).getComponent(face.axis);
      return (local.getComponent(face.axis) >= midpoint ? 1 : -1) === face.sign;
    });
    const candidates = [];
    for (const face of faces) {
      group.position.copy(start);
      if (this.snap(group, face, true)) candidates.push({ face, position: group.position.clone(), distance: group.position.distanceToSquared(start) });
    }
    if (!candidates.length) {
      for (const face of faces) {
        const center = face.surface.bounds.getCenter(new THREE.Vector3());
        const tangents = axes.filter(axis => axis !== face.axis);
        for (const horizontal of [0.5, 0.25, 0.75, 0.1, 0.9]) for (const vertical of [0.5, 0.25, 0.75]) {
          const point = center.clone();
          for (const [index, fraction] of [horizontal, vertical].entries()) {
            const axis = tangents[index];
            point.setComponent(axis, THREE.MathUtils.lerp(face.surface.bounds.min.getComponent(axis), face.surface.bounds.max.getComponent(axis), fraction));
          }
          group.position.copy(point.applyMatrix4(face.surface.mesh.matrixWorld));
          if (this.snap(group, face, true)) candidates.push({ face, position: group.position.clone(), distance: group.position.distanceToSquared(start) });
        }
      }
    }
    const best = candidates.sort((first, second) => first.distance - second.distance)[0];
    group.position.copy(best?.position ?? start); group.updateMatrixWorld(true);
    if (best) this.support = best.face;
    return Boolean(best);
  }

  attach(group, hit) {
    const surface = this.surfaces.find(surface => surface.mesh === hit.object);
    if (!surface || hit.object.userData.kind === 'decoration') return false;
    const components = hit.face.normal.toArray().map(Math.abs);
    const axis = components.indexOf(Math.max(...components));
    const face = { surface, axis, sign: Math.sign(hit.face.normal.getComponent(axis)) };
    const normal = this.normal(face);
    if (normal.y < -0.1 || (normal.y <= 0.99 && Math.abs(normal.y) >= 0.1)) return false;
    const position = group.position.clone();
    if (!this.snap(group, face, true)) { group.position.copy(position); group.updateMatrixWorld(true); return false; }
    this.support = face;
    return true;
  }

  groundAt(group, candidate) {
    const start = group.position.clone(), feet = this.body(group).bounds.min.y;
    const destinations = [];
    for (const face of this.faces().filter(face => this.normal(face).y > 0.99)) {
      group.position.set(candidate.x, start.y, candidate.z);
      if (this.snap(group, face) && this.body(group).bounds.min.y <= feet + 0.001) {
        destinations.push({ face, position: group.position.clone() });
      }
    }
    group.position.copy(start);
    for (const destination of destinations.sort((first, second) => second.position.y - first.position.y)) {
      let clear = true;
      for (const target of [new THREE.Vector3(destination.position.x, start.y, destination.position.z), destination.position]) {
        const origin = group.position.clone(), distance = origin.distanceTo(target);
        const steps = Math.max(1, Math.ceil(distance / 0.015));
        for (let index = 1; index <= steps; index++) {
          group.position.lerpVectors(origin, target, index / steps);
          if (this.obstruction(group)) { clear = false; break; }
        }
        if (!clear) break;
      }
      if (clear) { this.support = destination.face; group.updateMatrixWorld(true); return true; }
      group.position.copy(start);
    }
    group.updateMatrixWorld(true);
    return false;
  }

  translate(group, candidate) {
    if (!this.support || !candidate.toArray().every(Number.isFinite) || candidate.distanceTo(group.position) > 30) return false;
    const normal = this.normal(this.support), delta = candidate.clone().sub(group.position);
    if (Math.abs(normal.y) < 0.1 && delta.dot(normal) > 0.003 && this.groundAt(group, candidate)) return true;
    const moved = this.move(group, candidate);
    const remaining = candidate.clone().sub(group.position).setY(0).length();
    if (normal.y > 0.99 && remaining > 0.015 && this.groundAt(group, candidate)) return true;
    return moved;
  }

  move(group, candidate) {
    if (!this.support) return false;
    const start = group.position.clone(), normal = this.normal(this.support);
    const delta = candidate.clone().sub(start);
    delta.addScaledVector(normal, -delta.dot(normal));
    if (!Number.isFinite(delta.lengthSq()) || delta.length() > 30) return false;
    const steps = Math.max(1, Math.ceil(delta.length() / 0.015)), step = delta.divideScalar(steps);
    const basis = axes.filter(axis => axis !== this.support.axis).map(axis =>
      new THREE.Vector3().setComponent(axis, 1).transformDirection(this.support.surface.mesh.matrixWorld));
    for (let index = 0; index < steps; index++) {
      const before = group.position.clone();
      group.position.add(step);
      if (this.snap(group, this.support)) continue;
      group.position.copy(before);
      for (const tangent of basis) {
        const safe = group.position.clone();
        group.position.addScaledVector(tangent, step.dot(tangent));
        if (!this.snap(group, this.support)) group.position.copy(safe);
      }
    }
    group.updateMatrixWorld(true);
    return group.position.distanceToSquared(start) > 1e-12;
  }

  report(group) {
    let gap = null;
    if (this.support) {
      group.updateMatrixWorld(true);
      const { surface, axis, sign } = this.support, normal = this.normal(this.support);
      const plane = surface.bounds.getCenter(new THREE.Vector3())
        .setComponent(axis, (sign > 0 ? surface.bounds.max : surface.bounds.min).getComponent(axis)).applyMatrix4(surface.mesh.matrixWorld);
      gap = Math.min(...this.points.map(point => point.clone().applyMatrix4(group.matrixWorld).sub(plane).dot(normal)));
    }
    return { surface: this.support?.surface.mesh.name ?? null, normal: this.support ? this.normal(this.support).toArray() : null,
      gap, collision: this.obstruction(group) };
  }
}
