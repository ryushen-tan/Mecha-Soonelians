import test from 'node:test';
import assert from 'node:assert/strict';
import * as THREE from 'three';
import { RoomStage } from './room.js';
import { boneName, HumanoidRig } from './rig.js';
import { SurfacePainter } from './paint.js';
import { SurfacePlacement } from './surface-placement.js';
import { ObjectManipulator, dragPosition, transformPlacement } from './manipulation.js';

test('direct dragging maps the pointer to a wall and stays stable at a floor horizon', () => {
  const camera = new THREE.PerspectiveCamera(38, 1, 0.01, 100);
  camera.position.set(0, 1, -4); camera.lookAt(0, 1, 0); camera.updateMatrixWorld(true);
  const start = { position: new THREE.Vector3(), hit: new THREE.Vector3(0, 1, 0), pointer: new THREE.Vector2() };
  const wall = dragPosition(start, new THREE.Vector2(0.2, 0.2), camera, new THREE.Vector3(0, 0, -1));
  assert.ok(wall.x < 0 && wall.y > 0);
  assert.ok(Math.abs(wall.z) < 1e-8);
  const floor = dragPosition(start, new THREE.Vector2(0.2, 0.2), camera, new THREE.Vector3(0, 1, 0));
  assert.ok(floor.x < 0 && floor.z > 0);
  assert.equal(floor.y, 0);
  assert.ok(floor.length() < 1);
});

test('object transforms rotate all three axes, resize uniformly and remain surface supported', () => {
  const { body, constraint } = placementFixture([testFloor]);
  for (const axis of [new THREE.Vector3(1, 0, 0), new THREE.Vector3(0, 1, 0), new THREE.Vector3(0, 0, 1)]) {
    const rotation = new THREE.Quaternion().setFromAxisAngle(axis, Math.PI / 3);
    assert.equal(transformPlacement(body, constraint, { position: body.position.clone(), rotation, scale: body.scale.x }, 'rotate'), true);
    assert.ok(body.quaternion.angleTo(rotation) < 1e-6);
    assert.equal(constraint.obstruction(body), null);
    assert.ok(Math.abs(constraint.report(body).gap - 0.006) < 1e-6);
  }
  assert.equal(transformPlacement(body, constraint, { position: body.position.clone(), rotation: body.quaternion.clone(), scale: 0.45 }, 'scale'), true);
  assert.deepEqual(body.scale.toArray(), [0.45, 0.45, 0.45]);
  assert.equal(constraint.obstruction(body), null);
});

test('direct selection exposes rotation gizmos and cancellation restores the original object', () => {
  const { stage, body, constraint } = placementFixture([testFloor]);
  stage.scene.add(body);
  const camera = new THREE.PerspectiveCamera(38, 1, 0.01, 100);
  camera.position.set(0, 1, -4); camera.lookAt(0, 1, 0); camera.updateMatrixWorld(true);
  let changes = 0, selected = false;
  const manipulator = new ObjectManipulator(stage.scene, camera, body, constraint,
    { selection: value => { selected = value; }, change: () => changes++, end: () => {} });
  manipulator.configure(true);
  const start = body.position.clone();
  assert.equal(manipulator.begin({ x: 0, y: 0 }, { point: new THREE.Vector3(0, 1, 0) }), true);
  assert.equal(selected, true);
  manipulator.move({ x: 0.15, y: 0.1 });
  assert.ok(body.position.distanceTo(start) > 0.05);
  manipulator.end(true);
  assert.ok(body.position.distanceTo(start) < 1e-6);
  assert.ok(changes >= 2);
  manipulator.configure(true, 'rotate');
  assert.deepEqual(manipulator.report().axes, ['X', 'Y', 'Z']);
  assert.equal(manipulator.control.mode, 'rotate');
  manipulator.configure(false);
  assert.equal(manipulator.begin({ x: 0, y: 0 }, { point: new THREE.Vector3() }), false);
  assert.equal(manipulator.helper.visible, false);
});

function placementFixture(surfaces, size = [0.6, 1.8, 0.4]) {
  const stage = new RoomStage(new THREE.Scene());
  if (surfaces) stage.setRoom({ name: 'Constraint test', surfaces });
  const body = new THREE.Group(), mesh = new THREE.Mesh(new THREE.BoxGeometry(...size));
  mesh.position.y = size[1] / 2; body.add(mesh);
  const constraint = new SurfacePlacement(stage);
  constraint.refresh(body);
  assert.equal(constraint.repair(body), true);
  return { stage, body, mesh, constraint };
}

const testFloor = { id: 'floor', kind: 'floor', dimensions: [6, 0.1, 6], position: [0, -0.05, 0] };

test('a sideways drag can leave a side wall and land on the floor without crossing the wall', () => {
  const { stage, body, constraint } = placementFixture([testFloor,
    { id: 'side-wall', kind: 'wall', dimensions: [0.1, 3, 6], position: [-1, 1.5, 0] }]);
  body.position.set(-0.644, 0.6, 0);
  const wall = stage.surfaces.find(surface => surface.name === 'side-wall');
  const hit = new THREE.Raycaster(new THREE.Vector3(1, 1, 0), new THREE.Vector3(-1, 0, 0)).intersectObject(wall)[0];
  assert.equal(constraint.attach(body, hit), true);
  const start = body.position.clone();
  const camera = new THREE.PerspectiveCamera(38, 1, 0.01, 100);
  camera.position.set(start.x, 1.4, -4); camera.lookAt(start.x, 1.4, 0); camera.updateMatrixWorld(true);
  const target = dragPosition({position:start, pointer:new THREE.Vector2(), hit:new THREE.Vector3(start.x,1.4,0)},
    new THREE.Vector2(-0.2, 0), camera, constraint.normal(constraint.support));
  assert.ok(target.x > start.x + 0.1);
  assert.equal(constraint.translate(body, target), true);
  assert.ok(body.position.x > start.x + 0.1);
  assert.equal(constraint.report(body).surface, 'floor');
  assert.equal(constraint.obstruction(body), null);
  assert.ok(Math.abs(constraint.report(body).gap - 0.006) < 1e-6);
  constraint.translate(body, new THREE.Vector3(-2, body.position.y, body.position.z));
  assert.ok(body.position.x > -0.66, 'Dragging the other way must not cross through the wall.');
});

test('grabbing a selected torso prefers body movement over an overlapping vertical handle', () => {
  const {stage, body, constraint} = placementFixture([testFloor]);
  stage.scene.add(body);
  const camera = new THREE.PerspectiveCamera(38, 1, 0.01, 100);
  camera.position.set(0, 1, -4); camera.lookAt(0, 1, 0); camera.updateMatrixWorld(true);
  const manipulator = new ObjectManipulator(stage.scene, camera, body, constraint, {selection:()=>{},change:()=>{},end:()=>{}});
  manipulator.configure(true); manipulator.select(true);
  let pointer, hit;
  for (const point of manipulator.report().handles.Y) {
    const ray = new THREE.Raycaster(); ray.setFromCamera(new THREE.Vector2(point[0], point[1]), camera);
    const candidate = ray.intersectObject(body, true)[0];
    manipulator.control.pointerHover({x:point[0], y:point[1]});
    if (candidate && manipulator.control.axis === 'Y') { pointer = {x:point[0], y:point[1]}; hit = candidate; break; }
  }
  assert.ok(hit);
  manipulator.begin(pointer, hit);
  assert.equal(manipulator.gesture.kind, 'body');
  const start = body.position.clone();
  manipulator.move({x:pointer.x + 0.15, y:pointer.y});
  assert.ok(body.position.distanceTo(start) > 0.05);
  assert.equal(constraint.obstruction(body), null);
  manipulator.end();
});

test('cancelling a drag that leaves a wall restores both position and wall support', () => {
  const {stage, body, constraint} = placementFixture([testFloor,
    {id:'side-wall', kind:'wall', dimensions:[0.1,3,6], position:[-1,1.5,0]}]);
  stage.scene.add(body); body.position.set(-0.644, 0.6, 0);
  const wall = stage.surfaces.find(surface => surface.name === 'side-wall');
  const hit = new THREE.Raycaster(new THREE.Vector3(1,1,0), new THREE.Vector3(-1,0,0)).intersectObject(wall)[0];
  assert.equal(constraint.attach(body, hit), true);
  const position = body.position.clone(), support = constraint.support;
  const camera = new THREE.PerspectiveCamera(38,1,0.01,100);
  camera.position.set(position.x,1.4,-4); camera.lookAt(position.x,1.4,0); camera.updateMatrixWorld(true);
  const manipulator = new ObjectManipulator(stage.scene,camera,body,constraint,{selection:()=>{},change:()=>{},end:()=>{}});
  manipulator.configure(true);
  manipulator.begin({x:0,y:0},{point:new THREE.Vector3(position.x,1.4,0)});
  manipulator.move({x:-0.2,y:0});
  assert.equal(constraint.report(body).surface,'floor');
  manipulator.end(true);
  assert.ok(body.position.distanceTo(position)<1e-6);
  assert.equal(constraint.support,support);
  assert.equal(constraint.obstruction(body),null);
  assert.ok(Math.abs(constraint.report(body).gap-0.006)<1e-6);
});

test('surface movement stays grounded, stops at floor edges and cannot tunnel through thin obstacles', () => {
  const { body, constraint } = placementFixture([testFloor,
    { id: 'thin-wall', kind: 'wall', dimensions: [0.035, 3, 6], position: [1, 1.5, 0] }]);
  assert.ok(Math.abs(body.position.y - 0.006) < 1e-6);
  constraint.move(body, body.position.clone().add(new THREE.Vector3(0, 2, 0)));
  assert.ok(Math.abs(body.position.y - 0.006) < 1e-6, 'Height must not make a floor-supported person float.');
  constraint.move(body, body.position.clone().add(new THREE.Vector3(4, 0, 0)));
  assert.ok(body.position.x < 0.69, 'A long movement must stop on the near side of the wall.');
  assert.ok(body.position.x > 0.65);
  assert.equal(constraint.obstruction(body), null);
  constraint.move(body, body.position.clone().add(new THREE.Vector3(-10, 0, 0)));
  assert.ok(body.position.x >= -2.694 - 1e-5);
  assert.equal(constraint.report(body).surface, 'floor');
});

test('blocked diagonal movement slides along furniture rather than entering it', () => {
  const { body, constraint } = placementFixture([testFloor,
    { id: 'cabinet', kind: 'object', dimensions: [0.6, 1, 2], position: [1, 0.5, 0] }]);
  constraint.move(body, body.position.clone().add(new THREE.Vector3(1, 0, 0.5)));
  assert.ok(body.position.x < 0.4);
  assert.ok(body.position.z > 0.45);
  assert.equal(constraint.obstruction(body), null);
});

test('wall attachment raycasts solid support and slides vertically without going through the wall', () => {
  const { stage, body, constraint } = placementFixture([testFloor,
    { id: 'wall', kind: 'wall', dimensions: [4, 3, 0.1], position: [0, 1.5, 2] }]);
  const wall = stage.surfaces.find(mesh => mesh.name === 'wall');
  const hit = new THREE.Raycaster(new THREE.Vector3(0, 0.9, 0), new THREE.Vector3(0, 0, 1)).intersectObject(wall)[0];
  assert.ok(hit);
  assert.equal(constraint.attach(body, hit), true);
  const initial = body.position.clone();
  constraint.move(body, initial.clone().add(new THREE.Vector3(0.5, 0.5, 2)));
  assert.ok(Math.abs(body.position.z - initial.z) < 1e-5);
  assert.ok(body.position.y > 0.49);
  assert.ok(body.position.x > 0.49);
  constraint.move(body, body.position.clone().add(new THREE.Vector3(0, 5, 0)));
  assert.ok(body.position.y + 1.8 <= 3 - 0.006 + 1e-5);
  assert.equal(constraint.obstruction(body), null);
});

test('doors permit a fitting floor-supported body but wall attachment cannot straddle an opening', () => {
  const { stage, body, constraint } = placementFixture([testFloor,
    { id: 'door-wall', kind: 'wall', dimensions: [4, 3, 0.1], position: [0, 1.5, 1], holes: [[0, -0.5, 1, 2]] }]);
  constraint.move(body, body.position.clone().add(new THREE.Vector3(0, 0, 2)));
  assert.ok(body.position.z > 1.9);
  assert.equal(constraint.obstruction(body), null);
  const wall = stage.surfaces.find(mesh => mesh.name === 'door-wall');
  const hit = new THREE.Raycaster(new THREE.Vector3(0.6, 0.9, -1), new THREE.Vector3(0, 0, 1)).intersectObject(wall)[0];
  assert.ok(hit);
  body.position.set(0.6, 0.006, 0);
  assert.equal(constraint.attach(body, hit), false, 'The body width overlaps the doorway even when its center hits a wall.');
  body.position.set(1, 0.006, 0);
  assert.equal(constraint.attach(body, hit), true);
  constraint.move(body, body.position.clone().add(new THREE.Vector3(-2, 0, 0)));
  assert.ok(body.position.x >= 0.8 - 1e-5, 'Wall sliding must stop at a door edge.');
});

test('RoomPlan floor transforms and rotated walls use local oriented collision volumes', () => {
  const floorMatrix = new THREE.Matrix4().makeRotationX(-Math.PI / 2).setPosition(2, 0, -1);
  const wallMatrix = new THREE.Matrix4().makeRotationY(Math.PI / 4).setPosition(2, 1.5, -1);
  const { body, constraint } = placementFixture([
    { id: 'rotated-floor', kind: 'floor', dimensions: [8, 8, 0.1], transform: floorMatrix.toArray() },
    { id: 'diagonal-wall', kind: 'wall', dimensions: [5, 3, 0.06], transform: wallMatrix.toArray() }
  ]);
  assert.ok(Math.abs(body.position.y - 0.056) < 1e-5);
  assert.equal(constraint.obstruction(body), null);
  const start = body.position.clone();
  constraint.move(body, start.clone().add(new THREE.Vector3(5, 0, 0)));
  assert.equal(constraint.obstruction(body), null);
  assert.ok(body.position.x < 4.9);
});

test('pose, turn and size changes re-fit the entire body and repair old embedded placements', () => {
  const { body, mesh, constraint } = placementFixture();
  body.position.set(-2.25, 0.1, 1.6);
  constraint.support = null;
  constraint.refresh(body);
  assert.equal(constraint.obstruction(body), 'sofa');
  assert.equal(constraint.repair(body), true);
  assert.equal(constraint.obstruction(body), null);
  assert.ok(body.position.z < 2.74, 'Repair must not choose the outside of the room wall.');
  assert.equal(constraint.repair(body, true), true);
  assert.equal(constraint.report(body).surface, 'floor');
  body.position.set(0, 0.006, 0);
  mesh.scale.set(1.8, 1.2, 2);
  body.rotation.y = Math.PI / 3;
  body.scale.setScalar(1.5);
  constraint.refresh(body);
  assert.equal(constraint.repair(body), true);
  assert.equal(constraint.obstruction(body), null);
  assert.ok(constraint.report(body).surface);
});

test('a body cannot be attached to furniture that has no space for its full footprint', () => {
  const { stage, body, constraint } = placementFixture([testFloor,
    { id: 'tiny-stool', kind: 'object', dimensions: [0.2, 0.5, 0.2], position: [1, 0.25, 0] }]);
  const stool = stage.surfaces.find(mesh => mesh.name === 'tiny-stool');
  body.position.set(1, 0.5, 0);
  const hit = new THREE.Raycaster(new THREE.Vector3(1, 2, 0), new THREE.Vector3(0, -1, 0)).intersectObject(stool)[0];
  assert.equal(constraint.attach(body, hit), false);
  constraint.refresh(body);
  assert.equal(constraint.repair(body, true), true);
  assert.equal(constraint.report(body).surface, 'floor');
  assert.equal(constraint.obstruction(body), null);
});

test('a blocked pose expansion cannot switch to the opposite side of its attached wall', () => {
  const { stage, body, mesh, constraint } = placementFixture([testFloor,
    { id: 'back', kind: 'wall', dimensions: [4, 3, 0.1], position: [0, 1.5, 2] },
    { id: 'front', kind: 'wall', dimensions: [4, 3, 0.1], position: [0, 1.5, 0.8] }]);
  const wall = stage.surfaces.find(mesh => mesh.name === 'back');
  const hit = new THREE.Raycaster(new THREE.Vector3(0, 1, 1.1), new THREE.Vector3(0, 0, 1)).intersectObject(wall)[0];
  assert.equal(constraint.attach(body, hit), true);
  const position = body.position.clone();
  mesh.scale.z = 4;
  constraint.refresh(body);
  assert.equal(constraint.repair(body), false);
  assert.ok(body.position.distanceTo(position) < 1e-6);
  assert.ok(constraint.normal(constraint.support).z < -0.99);
});

test('repeated movement and changing silhouettes never lose support or enter room geometry', () => {
  const { body, mesh, constraint } = placementFixture([testFloor]);
  let seed = 3521;
  const random = () => { seed = (seed * 1664525 + 1013904223) >>> 0; return seed / 2 ** 32; };
  for (let frame = 0; frame < 300; frame++) {
    if (frame % 30 === 0) {
      mesh.scale.set(0.5 + random() * 1.5, 0.5 + random(), 0.5 + random());
      body.rotation.y = random() * Math.PI * 2;
      constraint.refresh(body);
      assert.equal(constraint.repair(body), true);
    }
    constraint.move(body, body.position.clone().add(new THREE.Vector3(random() - 0.5, random() - 0.5, random() - 0.5)));
    const report = constraint.report(body);
    assert.equal(report.collision, null);
    assert.ok(Math.abs(report.gap - 0.006) < 1e-6);
  }
});

test('switching from a brush stroke to two fingers restores paint without changing undo or redo', () => {
  const painter = Object.create(SurfacePainter.prototype);
  const state = { packed: new Uint32Array([1, 2, 3]) };
  painter.states = [state]; painter.undoStack = []; painter.redoStack = ['existing redo'];
  let refreshed = 0;
  painter.refresh = () => refreshed++;
  painter.begin(); state.packed[0] = 99;
  painter.cancelStroke();
  assert.deepEqual([...state.packed], [1, 2, 3]);
  assert.equal(painter.end(), false);
  assert.equal(painter.undoStack.length, 0);
  assert.deepEqual(painter.redoStack, ['existing redo']);
  assert.equal(refreshed, 1);
});

test('Mixamo names survive both GLB-loader sanitizing and namespaces', () => {
  for (const name of ['mixamorig:LeftArm', 'mixamorigLeftArm', 'mixamorig1_LeftArm', 'Armature|mixamorig:LeftArm']) {
    assert.equal(boneName(name), 'leftarm');
  }
});

test('poses use the captured body axes rather than assuming a GLB facing direction', () => {
  for (const yaw of [0, Math.PI / 2, -Math.PI / 3, Math.PI]) {
    const character = new THREE.Group(), armature = new THREE.Group(), bones = [];
    character.add(armature); armature.rotation.y = yaw;
    const add = (parent, name, position) => {
      const bone = new THREE.Bone(); bone.name = 'mixamorig' + name; bone.position.fromArray(position);
      parent.add(bone); bones.push(bone); return bone;
    };
    const hips = add(armature, 'Hips', [0, 1, 0]);
    const spine = add(hips, 'Spine', [0, 0.15, 0]);
    const spine1 = add(spine, 'Spine1', [0, 0.15, 0]);
    const spine2 = add(spine1, 'Spine2', [0, 0.15, 0]);
    for (const [side, sign] of [['Left', -1], ['Right', 1]]) {
      const arm = add(spine2, side + 'Arm', [sign * 0.2, 0, 0]);
      const forearm = add(arm, side + 'ForeArm', [sign * 0.3, 0, 0]);
      add(forearm, side + 'Hand', [sign * 0.3, 0, 0]);
      const thigh = add(hips, side + 'UpLeg', [sign * 0.1, 0, 0]);
      const shin = add(thigh, side + 'Leg', [0, -0.45, 0]);
      const foot = add(shin, side + 'Foot', [0, -0.45, 0]);
      add(foot, side + 'ToeBase', [0, 0, -0.15]);
    }
    const geometry = new THREE.BufferGeometry();
    geometry.setAttribute('position', new THREE.Float32BufferAttribute([], 3));
    const mesh = new THREE.SkinnedMesh(geometry); character.add(mesh);
    character.updateMatrixWorld(true); mesh.bind(new THREE.Skeleton(bones));
    const rig = new HumanoidRig(character); rig.select('tpose', {}, true);
    for (const [side, sign] of [['left', -1], ['right', 1]]) {
      const arm = rig.named.get(side + 'arm').getWorldPosition(new THREE.Vector3());
      const forearm = rig.named.get(side + 'forearm').getWorldPosition(new THREE.Vector3());
      assert.ok(forearm.sub(arm).normalize().dot(rig.right.clone().multiplyScalar(sign)) > 0.999);
    }
  }
});

test('attaching a body rests its actual surface on floors and walls', () => {
  const stage = new RoomStage(new THREE.Scene());
  const body = new THREE.Group();
  const mesh = new THREE.Mesh(new THREE.BoxGeometry(0.6, 1.8, 0.4));
  mesh.position.y = 0.9;
  body.add(mesh);
  const floor = new THREE.Mesh(new THREE.PlaneGeometry(10, 10));
  floor.userData.kind = 'floor';
  const floorPoint = new THREE.Vector3(0.8, 0.2, 0.4);
  stage.attach(body, { point: floorPoint, face: { normal: new THREE.Vector3(0, 1, 0) }, object: floor });
  assert.ok(Math.abs(new THREE.Box3().setFromObject(body).min.y - 0.206) < 0.00001);
  const wall = new THREE.Mesh(new THREE.BoxGeometry(5, 3, 0.1));
  wall.userData.kind = 'wall';
  const wallPoint = new THREE.Vector3(0, 1, 2);
  stage.attach(body, { point: wallPoint, face: { normal: new THREE.Vector3(0, 0, -1) }, object: wall });
  assert.ok(Math.abs(new THREE.Box3().setFromObject(body).max.z - 1.994) < 0.00001);
});

test('door holes affect real room triangles and hunter spawns are inside the floor', () => {
  const stage = new RoomStage(new THREE.Scene());
  stage.setRoom({ name: 'Door test', surfaces: [
    { id: 'floor', kind: 'floor', dimensions: [6, 0.1, 6], position: [0, -0.05, 0] },
    { id: 'wall', kind: 'wall', dimensions: [4, 3, 0.1], position: [0, 1.5, 1], holes: [[0, -0.5, 1, 2]] }
  ] });
  stage.show(true);
  const doorRay = new THREE.Raycaster(new THREE.Vector3(0, 1, -2), new THREE.Vector3(0, 0, 1));
  assert.equal(doorRay.intersectObjects(stage.surfaces, false).length, 0);
  doorRay.ray.origin.x = 1;
  assert.ok(doorRay.intersectObjects(stage.surfaces, false).length > 0);
  const spawn = stage.spawn();
  assert.ok(spawn.position.x > -3 && spawn.position.x < 3);
  assert.ok(spawn.position.z > -3 && spawn.position.z < 3);
  assert.ok(Math.abs(spawn.position.y - 1.6) < 0.00001);
});

test('paint view chooses a solid wall and aligns different model facing directions', () => {
  for (const forward of [new THREE.Vector3(1, 0, 0), new THREE.Vector3(0, 0, -1)]) {
    const stage = new RoomStage(new THREE.Scene());
    const body = new THREE.Group();
    const mesh = new THREE.Mesh(new THREE.BoxGeometry(0.6, 1.8, 0.4));
    mesh.position.y = 0.9; body.add(mesh);
    const wall = stage.paintWall(body);
    assert.ok(wall);
    const attached = stage.attach(body, wall, forward);
    assert.ok(forward.clone().applyQuaternion(body.quaternion).dot(wall.worldNormal) > 0.999);
    const bounds = new THREE.Box3().setFromObject(body);
    assert.ok(Math.abs(bounds.min.y - 0.006) < 0.00001);
    assert.ok(attached.position.every(Number.isFinite));
    assert.equal(stage.collision(body, bounds), null);
  }
});

test('paint backdrop avoids doorway holes rather than placing a person in empty space', () => {
  const stage = new RoomStage(new THREE.Scene());
  stage.setRoom({ name: 'Door backdrop', surfaces: [
    { id: 'wall', kind: 'wall', dimensions: [4, 3, 0.1], position: [0, 1.5, 2], holes: [[0, -0.5, 1, 2]] }
  ] });
  const body = new THREE.Group();
  const mesh = new THREE.Mesh(new THREE.BoxGeometry(0.6, 1.8, 0.4));
  mesh.position.y = 0.9; body.add(mesh);
  const wall = stage.paintWall(body);
  assert.ok(wall);
  assert.ok(Math.abs(wall.point.x) > 0.5);
  stage.setRoom({ name: 'No walls', surfaces: [{ id: 'floor', kind: 'floor', dimensions: [6, 0.1, 6] }] });
  assert.equal(stage.paintWall(body), null);
});
