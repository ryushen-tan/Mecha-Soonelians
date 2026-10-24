import { readFileSync } from 'node:fs';

// The rig fixture with disguise bounds, as the app publishes it (same as game.test.mjs).
export function disguiseGLB(boxes = [{ id: '0', min: [-0.3, 0, -0.3], max: [0.3, 1.8, 0.3] }]) {
  const data = readFileSync(new URL('../../TestFixtures/Character3D/test-rig.glb', import.meta.url));
  const length = data.readUInt32LE(12);
  const json = JSON.parse(data.subarray(20, 20 + length));
  json.nodes[0].extras = { disguises: boxes };
  const text = Buffer.from(JSON.stringify(json));
  const padded = Buffer.alloc(Math.ceil(text.length / 4) * 4, 32);
  text.copy(padded);
  const header = Buffer.alloc(20);
  header.write('glTF'); header.writeUInt32LE(2, 4); header.writeUInt32LE(20 + padded.length + data.length - 20 - length, 8);
  header.writeUInt32LE(padded.length, 12); header.writeUInt32LE(0x4e4f534a, 16);
  return Buffer.concat([header, padded, data.subarray(20 + length)]);
}
