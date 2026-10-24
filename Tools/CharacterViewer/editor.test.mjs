import test from 'node:test';
import assert from 'node:assert/strict';
import * as THREE from 'three';
import { RoomStage } from './room.js';
import { boneName, HumanoidRig } from './rig.js';

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
