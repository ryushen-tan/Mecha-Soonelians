import * as THREE from 'three';
import { GLTFExporter } from 'three/addons/exporters/GLTFExporter.js';
import { mkdirSync, writeFileSync } from 'node:fs';

globalThis.FileReader = class {
  readAsArrayBuffer(blob) {
    blob.arrayBuffer().then(result => { this.result = result; this.onloadend?.(); });
  }
  readAsDataURL(blob) {
    blob.arrayBuffer().then(result => {
      this.result = `data:${blob.type};base64,${Buffer.from(result).toString('base64')}`;
      this.onloadend?.();
    });
  }
};

const geometry = new THREE.CylinderGeometry(0.3, 0.3, 2, 8, 8);
geometry.translate(0, 1, 0);
const position = geometry.attributes.position;
const indices = [];
const weights = [];
for (let index = 0; index < position.count; index++) {
  const weight = Math.max(0, Math.min(1, position.getY(index) - 0.5));
  indices.push(0, 1, 0, 0);
  weights.push(1 - weight, weight, 0, 0);
}
geometry.setAttribute('skinIndex', new THREE.Uint16BufferAttribute(indices, 4));
geometry.setAttribute('skinWeight', new THREE.Float32BufferAttribute(weights, 4));
const root = new THREE.Bone();
root.name = 'TestRoot';
const tip = new THREE.Bone();
tip.name = 'TestTip';
tip.position.y = 1;
root.add(tip);
const mesh = new THREE.SkinnedMesh(geometry, new THREE.MeshStandardMaterial({ color: 0xd4ed5e }));
mesh.name = 'Synthetic test rig, not a generated human';
mesh.add(root);
mesh.bind(new THREE.Skeleton([root, tip]));
const scene = new THREE.Scene();
scene.add(mesh);
const result = await new GLTFExporter().parseAsync(scene, { binary: true });
const directory = new URL('../../TestFixtures/Character3D/', import.meta.url);
mkdirSync(directory, { recursive: true });
writeFileSync(new URL('test-rig.glb', directory), Buffer.from(result));
