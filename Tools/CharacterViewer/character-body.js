import * as THREE from 'three';
import { clone } from 'three/addons/utils/SkeletonUtils.js';
import { HumanoidRig, posePages } from './rig.js';

export function bakeCharacterBody(character, sourceRig, painter) {
  if (!sourceRig.canRetarget) throw new Error('This model needs a compatible humanoid rig. Retake a standing full-body photo.');
  const body = clone(character);
  const root = new THREE.Group();
  root.add(body);
  const rig = new HumanoidRig(body);
  rig.bones.forEach((bone, index) => bone.quaternion.copy(sourceRig.rest[index]));
  const restRig = new HumanoidRig(body);
  const forward = restRig.forward.clone().applyQuaternion(body.quaternion);
  const facing = new THREE.Quaternion().setFromAxisAngle(new THREE.Vector3(0, 1, 0), -Math.atan2(forward.x, forward.z));
  const meshes = [];
  body.traverse(mesh => {
    if (!mesh.isMesh || !mesh.geometry.attributes.uv) return;
    for (let node = mesh; node && node !== body; node = node.parent) if (!node.visible) return;
    meshes.push(mesh);
  });
  const originals = [];
  character.traverse(mesh => {
    if (!mesh.isMesh || !mesh.geometry.attributes.uv) return;
    for (let node = mesh; node && node !== character; node = node.parent) if (!node.visible) return;
    originals.push(mesh);
  });
  const states = originals.flatMap(mesh => painter.byMesh.get(mesh) ?? []);
  if (!states.length) throw new Error('The model has no paintable surface.');
  const atlas = document.createElement('canvas');
  atlas.width = atlas.height = 1024;
  const context = atlas.getContext('2d');
  const tiles = Math.ceil(Math.sqrt(states.length)), tile = 1024 / tiles, inset = 2;
  states.forEach((state, index) => context.drawImage(state.canvas,
    index % tiles * tile + inset, Math.floor(index / tiles) * tile + inset, tile - inset * 2, tile - inset * 2));
  const references = [], indices = [], uvs = [], renumber = new Map();
  meshes.forEach((mesh, meshIndex) => {
    const geometry = mesh.geometry, count = geometry.index?.count ?? geometry.attributes.position.count;
    const groups = geometry.groups.length ? geometry.groups : [{ start: 0, count, materialIndex: 0 }];
    for (const group of groups) {
      const state = (painter.byMesh.get(originals[meshIndex]) ?? [])[group.materialIndex ?? 0];
      const atlasIndex = states.indexOf(state);
      if (atlasIndex < 0) throw new Error('A model material could not be mapped.');
      state.texture.updateMatrix();
      for (let offset = group.start; offset < Math.min(count, group.start + group.count); offset++) {
        const vertexIndex = geometry.index ? geometry.index.getX(offset) : offset;
        const key = `${meshIndex}:${group.materialIndex ?? 0}:${vertexIndex}`;
        if (!renumber.has(key)) {
          renumber.set(key, references.length);
          references.push({ mesh, vertexIndex });
          const uv = new THREE.Vector2().fromBufferAttribute(geometry.attributes.uv, vertexIndex);
          state.texture.transformUv(uv);
          uvs.push((atlasIndex % tiles * tile + inset + uv.x * (tile - inset * 2)) / 1024,
            1 - (Math.floor(atlasIndex / tiles) * tile + inset + uv.y * (tile - inset * 2)) / 1024);
        }
        indices.push(renumber.get(key));
      }
    }
  });
  if (!references.length || references.length > 150000 || indices.length > 300000 || indices.length % 3) {
    throw new Error('This model is too complex for the room editor. Use a simpler full-body scan.');
  }
  const poses = posePages.flat().filter(pose => pose.id !== 'original');
  const positions = poses.map(pose => {
    root.quaternion.copy(facing);
    restRig.select(pose.id, {}, true);
    if (['prone', 'side', 'lean'].includes(pose.id)) {
      const axis = (pose.id === 'prone' ? restRig.right : restRig.forward).clone().applyQuaternion(body.quaternion);
      const angle = pose.id === 'prone' ? -Math.PI / 2 : pose.id === 'side' ? Math.PI / 2 : 0.25;
      root.quaternion.multiply(new THREE.Quaternion().setFromAxisAngle(axis, angle));
    }
    root.updateMatrixWorld(true);
    meshes.forEach(mesh => { if (mesh.isSkinnedMesh) mesh.skeleton.update(); });
    const vertex = new THREE.Vector3();
    return new Float32Array(references.flatMap(({ mesh, vertexIndex }) => {
      mesh.getVertexPosition(vertexIndex, vertex).applyMatrix4(mesh.matrixWorld);
      return vertex.toArray();
    }));
  });
  const chunks = [new Float32Array(uvs), new Uint32Array(indices), ...positions];
  const data = new Uint8Array(chunks.reduce((size, chunk) => size + chunk.byteLength, 0));
  let offset = 0;
  for (const chunk of chunks) { data.set(new Uint8Array(chunk.buffer), offset); offset += chunk.byteLength; }
  return { info: { vertexCount: references.length, triangleCount: indices.length / 3, poses }, data,
    texture: atlas.toDataURL('image/png').split(',')[1] };
}
