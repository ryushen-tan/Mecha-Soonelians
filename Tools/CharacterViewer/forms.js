import * as THREE from 'three';
import { mergeGeometries } from 'three/addons/utils/BufferGeometryUtils.js';

export function buildBodyForms(character, rig) {
  if (!rig.canRetarget) return;
  character.updateMatrixWorld(true);
  let source;
  character.traverse(node => { if (node.isMesh) { node.userData.form = 'person'; if (node.isSkinnedMesh && !source) source = node; } });
  if (!source) return;
  const height = new THREE.Box3().setFromObject(character, true).getSize(new THREE.Vector3()).y;
  const parts = [
    ['hips', 'neck', 0.105], ['neck', 'head', 0.055], ['head', 'headtop_end', 0.085],
    ['leftarm', 'leftforearm', 0.035], ['leftforearm', 'lefthand', 0.03],
    ['rightarm', 'rightforearm', 0.035], ['rightforearm', 'righthand', 0.03],
    ['leftupleg', 'leftleg', 0.052], ['leftleg', 'leftfoot', 0.037],
    ['rightupleg', 'rightleg', 0.052], ['rightleg', 'rightfoot', 0.037],
    ['lefthand', 'lefthandmiddle1', 0.028], ['righthand', 'righthandmiddle1', 0.028],
    ['leftfoot', 'lefttoebase', 0.038], ['rightfoot', 'righttoebase', 0.038]
  ];
  for (const form of ['rounded', 'blocky']) {
    const geometries = [];
    parts.forEach(([startName, endName, fraction], partIndex) => {
      const startBone = rig.named.get(startName);
      let endBone = rig.named.get(endName);
      if (!startBone) return;
      endBone ??= startBone.children.find(child => child.isBone);
      if (!endBone || !source.skeleton.bones.includes(endBone)) return;
      const start = startBone.getWorldPosition(new THREE.Vector3());
      const end = endBone.getWorldPosition(new THREE.Vector3());
      const length = start.distanceTo(end);
      const radius = height * fraction;
      const head = startName === 'head';
      const geometry = form === 'blocky'
        ? new THREE.BoxGeometry(radius * 2, Math.max(length, radius * 2), radius * (startName === 'hips' ? 1.3 : 2), 1, 4, 1)
        : head ? new THREE.SphereGeometry(radius, 12, 8) : new THREE.CapsuleGeometry(radius, Math.max(0.005, length - 2 * radius), 4, 8, 4);
      const indices = new Uint16Array(geometry.attributes.position.count * 4);
      const weights = new Float32Array(indices.length);
      for (let index = 0; index < geometry.attributes.position.count; index++) {
        const position = geometry.attributes.position.getY(index);
        const amount = head ? 0 : THREE.MathUtils.clamp((position + length / 2) / Math.max(length, 0.01), 0, 1);
        indices[index * 4] = source.skeleton.bones.indexOf(startBone);
        indices[index * 4 + 1] = source.skeleton.bones.indexOf(endBone);
        weights[index * 4] = 1 - amount; weights[index * 4 + 1] = amount;
        const uv = geometry.attributes.uv;
        uv.setXY(index, (uv.getX(index) + partIndex % 5) / 5, (uv.getY(index) + Math.floor(partIndex / 5)) / 5);
      }
      geometry.setAttribute('skinIndex', new THREE.Uint16BufferAttribute(indices, 4));
      geometry.setAttribute('skinWeight', new THREE.Float32BufferAttribute(weights, 4));
      geometry.clearGroups();
      const center = head ? start.clone().add(end).multiplyScalar(0.5) : start.clone().add(end).multiplyScalar(0.5);
      const rotation = new THREE.Quaternion().setFromUnitVectors(new THREE.Vector3(0, 1, 0), end.clone().sub(start).normalize());
      const transform = new THREE.Matrix4().compose(center, rotation, new THREE.Vector3(1, 1, 1));
      geometry.applyMatrix4(source.matrixWorld.clone().invert().multiply(transform));
      geometries.push(geometry);
    });
    const merged = mergeGeometries(geometries, false);
    if (!merged) continue;
    const mesh = new THREE.SkinnedMesh(merged, new THREE.MeshStandardMaterial({ color: '#ffffff', roughness: 0.8 }));
    mesh.name = form === 'rounded' ? 'Rounded body' : 'Blocky body';
    mesh.userData.form = form; mesh.visible = false;
    mesh.position.copy(source.position); mesh.quaternion.copy(source.quaternion); mesh.scale.copy(source.scale);
    source.parent.add(mesh);
    mesh.bind(source.skeleton, source.bindMatrix);
  }
}
