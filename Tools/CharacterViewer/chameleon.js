import * as THREE from 'three';
import { mergeGeometries } from 'three/addons/utils/BufferGeometryUtils.js';

// A smooth, chubby, faceless Meccha-style figure (big round head, stubby rounded limbs, mitten
// hands), generated in code so it needs no model file. It faces +Z with its left side at +X,
// stands 1.75 m tall in an A-pose, and uses Mixamo bone names so the pose wheel (rig.js) works.
// Every part is a capsule or ball riding rigidly on one bone; the rounded ends overlap at the
// joints, so bending an elbow or knee stays seamless.

const HEIGHT = 1.75;
const ATLAS = 1024;
const ARM_DROP = THREE.MathUtils.degToRad(40);

// Bone name, parent, world position in the rest pose.
function skeletonLayout() {
  const arm = new THREE.Vector3(Math.cos(ARM_DROP), -Math.sin(ARM_DROP), 0);
  const bones = [
    ['Hips', null, [0, 0.82, 0]], ['Spine', 'Hips', [0, 0.92, 0]], ['Spine1', 'Spine', [0, 1.04, 0]],
    ['Spine2', 'Spine1', [0, 1.16, 0]], ['Neck', 'Spine2', [0, 1.3, 0]], ['Head', 'Neck', [0, 1.36, 0]],
    ['HeadTop_End', 'Head', [0, HEIGHT, 0]]
  ];
  for (const [side, sign] of [['Left', 1], ['Right', -1]]) {
    const shoulder = new THREE.Vector3(sign * 0.25, 1.24, 0);
    const along = arm.clone().setX(arm.x * sign);
    const elbow = shoulder.clone().addScaledVector(along, 0.24);
    const wrist = elbow.clone().addScaledVector(along, 0.21);
    const fingers = wrist.clone().addScaledVector(along, 0.1);
    bones.push(
      [side + 'Shoulder', 'Spine2', [sign * 0.1, 1.24, 0]], [side + 'Arm', side + 'Shoulder', shoulder.toArray()],
      [side + 'ForeArm', side + 'Arm', elbow.toArray()], [side + 'Hand', side + 'ForeArm', wrist.toArray()],
      [side + 'HandMiddle1', side + 'Hand', fingers.toArray()],
      [side + 'UpLeg', 'Hips', [sign * 0.12, 0.76, 0]], [side + 'Leg', side + 'UpLeg', [sign * 0.12, 0.43, 0]],
      [side + 'Foot', side + 'Leg', [sign * 0.12, 0.1, 0]], [side + 'ToeBase', side + 'Foot', [sign * 0.12, 0.04, 0.12]],
      [side + 'Toe_End', side + 'ToeBase', [sign * 0.12, 0.04, 0.17]]
    );
  }
  return bones;
}

// [bone, from, to, radius, squash (x, z scale of the cross-section)]. A ball has from == to.
function partLayout(world) {
  const p = name => world.get(name).toArray();
  const parts = [
    ['Hips', [0, 0.78, 0], [0, 0.98, 0], 0.2, [1.15, 0.85]],
    ['Spine1', [0, 0.98, 0], [0, 1.2, 0], 0.21, [1.12, 0.82]],
    ['Head', [0, 1.54, 0], [0, 1.54, 0], 0.21, [1, 0.95]]
  ];
  for (const side of ['Left', 'Right']) {
    const foot = world.get(side + 'Foot');
    parts.push(
      [side + 'Arm', p(side + 'Arm'), p(side + 'ForeArm'), 0.075, [1, 1]],
      [side + 'ForeArm', p(side + 'ForeArm'), p(side + 'Hand'), 0.068, [1, 1]],
      [side + 'Hand', p(side + 'HandMiddle1'), p(side + 'HandMiddle1'), 0.072, [0.85, 0.7]],
      [side + 'UpLeg', p(side + 'UpLeg'), p(side + 'Leg'), 0.1, [1, 1]],
      [side + 'Leg', p(side + 'Leg'), p(side + 'Foot'), 0.088, [1, 1]],
      [side + 'Foot', [foot.x, 0.06, 0.0], [foot.x, 0.06, 0.07], 0.06, [1.2, 1]]
    );
  }
  return parts.map(([bone, from, to, radius, squash]) => ({
    bone, from: new THREE.Vector3(...from), to: new THREE.Vector3(...to), radius, squash
  }));
}

/// Builds the skinned figure. Returns its parts (geometry, atlas cell, capsule for occlusion).
export function buildMannequin() {
  const world = new Map();
  const bones = new Map();
  for (const [name, parent, position] of skeletonLayout()) {
    const bone = new THREE.Bone();
    bone.name = name;
    const at = new THREE.Vector3(...position);
    world.set(name, at);
    bone.position.copy(parent ? at.clone().sub(world.get(parent)) : at);
    if (parent) bones.get(parent).add(bone);
    bones.set(name, bone);
  }
  const boneList = [...bones.values()];

  const parts = partLayout(world).map(part => {
    const axis = part.to.clone().sub(part.from);
    const length = axis.length();
    const geometry = length < 1e-4
      ? new THREE.SphereGeometry(part.radius, 32, 20)
      : new THREE.CapsuleGeometry(part.radius, length, 10, 28, 4);
    geometry.scale(part.squash[0], 1, part.squash[1]);
    const rotation = length < 1e-4 ? new THREE.Quaternion()
      : new THREE.Quaternion().setFromUnitVectors(new THREE.Vector3(0, 1, 0), axis.clone().normalize());
    geometry.applyQuaternion(rotation);
    const center = part.from.clone().add(part.to).multiplyScalar(0.5);
    geometry.translate(center.x, center.y, center.z);
    const boneIndex = boneList.indexOf(bones.get(part.bone));
    const count = geometry.attributes.position.count;
    geometry.setAttribute('skinIndex', new THREE.Uint16BufferAttribute(new Array(count).fill(0).flatMap(() => [boneIndex, 0, 0, 0]), 4));
    geometry.setAttribute('skinWeight', new THREE.Float32BufferAttribute(new Array(count).fill(0).flatMap(() => [1, 0, 0, 0]), 4));
    // Cell size in the texture: around the part by along it.
    const around = 2 * Math.PI * part.radius * (part.squash[0] + part.squash[1]) / 2;
    return { ...part, geometry, lengthU: around, lengthV: length + 2 * part.radius,
      radiusForOcclusion: part.radius * Math.min(...part.squash) };
  });
  packParts(parts);
  for (const part of parts) {
    const uvs = part.geometry.attributes.uv;
    for (let vertex = 0; vertex < uvs.count; vertex++) {
      uvs.setXY(vertex, (part.rect.x + uvs.getX(vertex) * part.rect.w) / ATLAS, (part.rect.y + uvs.getY(vertex) * part.rect.h) / ATLAS);
    }
  }
  return { parts, boneList, root: bones.get('Hips') };
}

/// Shelf-packs every part's cell into the atlas at the largest uniform texels-per-metre that fits.
function packParts(parts) {
  const order = [...parts].sort((a, b) => b.lengthV - a.lengthV);
  const fits = scale => {
    let x = 0, y = 0, row = 0;
    for (const part of order) {
      const w = Math.max(4, Math.floor(part.lengthU * scale)), h = Math.max(4, Math.floor(part.lengthV * scale));
      if (x + w + 4 > ATLAS) { x = 0; y += row + 4; row = 0; }
      if (y + h + 4 > ATLAS || w + 4 > ATLAS) return false;
      part.rect = { x: x + 2, y: y + 2, w, h };
      x += w + 4; row = Math.max(row, h);
    }
    return true;
  };
  let low = 1, high = 8000;
  for (let step = 0; step < 24; step++) { const middle = (low + high) / 2; if (fits(middle)) low = middle; else high = middle; }
  fits(low);
}

/// Distance along a ray (origin, direction) to a capsule, or Infinity. Used for occlusion.
function rayCapsule(origin, direction, a, b, radius) {
  // Sample along the capsule's axis; plenty for deciding whether one limb hides another.
  const steps = a.distanceTo(b) < 1e-4 ? 1 : 6;
  const point = new THREE.Vector3(), toPoint = new THREE.Vector3();
  for (let step = 0; step < steps; step++) {
    point.lerpVectors(a, b, steps === 1 ? 0 : step / (steps - 1));
    toPoint.subVectors(point, origin);
    const along = toPoint.dot(direction);
    if (along <= 0.01) continue;
    if (toPoint.lengthSq() - along * along < radius * radius) return along;
  }
  return Infinity;
}

/// Projects the turnaround photos onto the figure's texture.
/// Each view is a person cutout cropped head-to-feet, the turn in degrees (turning to their
/// right is positive), and where the hips are across the crop (0–1).
export function bakeTexture(mannequin, views, { faceless = true } = {}) {
  const canvas = document.createElement('canvas');
  canvas.width = canvas.height = ATLAS;
  const context = canvas.getContext('2d', { willReadFrequently: true });
  const atlas = context.createImageData(ATLAS, ATLAS);
  const samples = views.map(view => {
    const image = document.createElement('canvas');
    image.width = view.image.width; image.height = view.image.height;
    const imageContext = image.getContext('2d', { willReadFrequently: true });
    imageContext.drawImage(view.image, 0, 0);
    const turn = THREE.MathUtils.degToRad(view.yaw);
    return {
      pixels: imageContext.getImageData(0, 0, image.width, image.height).data, width: image.width, height: image.height,
      toCamera: new THREE.Vector3(Math.sin(turn), 0, Math.cos(turn)), right: new THREE.Vector3(Math.cos(turn), 0, -Math.sin(turn)),
      centerX: view.centerX ?? 0.5
    };
  });

  const color = (point, normal, others, skip) => {
    if (skip) return null;
    let red = 0, green = 0, blue = 0, total = 0;
    const start = point.clone().addScaledVector(normal, 0.004);
    for (const view of samples) {
      const facing = normal.dot(view.toCamera);
      if (facing < 0.15) continue;
      if (others.some(part => rayCapsule(start, view.toCamera, part.from, part.to, part.radiusForOcclusion) < Infinity)) continue;
      // Orthographic: head-to-feet of the figure spans the crop's height.
      const scale = view.height / HEIGHT;
      const px = Math.round(view.centerX * view.width + point.dot(view.right) * scale);
      const py = Math.round(view.height - point.y * scale);
      if (px < 0 || py < 0 || px >= view.width || py >= view.height) continue;
      const index = (py * view.width + px) * 4;
      if (view.pixels[index + 3] < 128) continue;
      const weight = facing ** 3;
      red += view.pixels[index] * weight; green += view.pixels[index + 1] * weight; blue += view.pixels[index + 2] * weight;
      total += weight;
    }
    return total ? [red / total, green / total, blue / total] : null;
  };

  const a = new THREE.Vector2(), b = new THREE.Vector2(), c = new THREE.Vector2();
  const pa = new THREE.Vector3(), pb = new THREE.Vector3(), pc = new THREE.Vector3();
  const na = new THREE.Vector3(), nb = new THREE.Vector3(), nc = new THREE.Vector3();
  for (const part of mannequin.parts) {
    const others = mannequin.parts.filter(other => other !== part);
    const { position, normal, uv } = part.geometry.attributes;
    const index = part.geometry.index;
    const centerZ = part.from.z;
    for (let triangle = 0; triangle < index.count; triangle += 3) {
      const [i, j, k] = [index.getX(triangle), index.getX(triangle + 1), index.getX(triangle + 2)];
      a.fromBufferAttribute(uv, i).multiplyScalar(ATLAS); b.fromBufferAttribute(uv, j).multiplyScalar(ATLAS); c.fromBufferAttribute(uv, k).multiplyScalar(ATLAS);
      pa.fromBufferAttribute(position, i); pb.fromBufferAttribute(position, j); pc.fromBufferAttribute(position, k);
      na.fromBufferAttribute(normal, i); nb.fromBufferAttribute(normal, j); nc.fromBufferAttribute(normal, k);
      const area = (b.x - a.x) * (c.y - a.y) - (c.x - a.x) * (b.y - a.y);
      if (Math.abs(area) < 1e-9) continue;
      const minX = Math.max(0, Math.floor(Math.min(a.x, b.x, c.x))), maxX = Math.min(ATLAS - 1, Math.ceil(Math.max(a.x, b.x, c.x)));
      const minY = Math.max(0, Math.floor(Math.min(a.y, b.y, c.y))), maxY = Math.min(ATLAS - 1, Math.ceil(Math.max(a.y, b.y, c.y)));
      for (let y = minY; y <= maxY; y++) {
        for (let x = minX; x <= maxX; x++) {
          const px = x + 0.5, py = y + 0.5;
          const w1 = ((b.x - px) * (c.y - py) - (c.x - px) * (b.y - py)) / area;
          const w2 = ((c.x - px) * (a.y - py) - (a.x - px) * (c.y - py)) / area;
          const w3 = 1 - w1 - w2;
          if (w1 < -0.01 || w2 < -0.01 || w3 < -0.01) continue;
          const point = pa.clone().multiplyScalar(w1).addScaledVector(pb, w2).addScaledVector(pc, w3);
          const surface = na.clone().multiplyScalar(w1).addScaledVector(nb, w2).addScaledVector(nc, w3).normalize();
          // Faceless: the front of the head stays white.
          const skip = faceless && part.bone === 'Head' && surface.z > 0.35 && point.z > centerZ;
          const rgb = color(point, surface, others, skip);
          const pixel = (y * ATLAS + x) * 4;
          // Anything no photo saw stays figure white.
          atlas.data[pixel] = rgb ? rgb[0] : 255;
          atlas.data[pixel + 1] = rgb ? rgb[1] : 255;
          atlas.data[pixel + 2] = rgb ? rgb[2] : 255;
          atlas.data[pixel + 3] = 255;
        }
      }
    }
  }
  dilate(atlas, 3);
  context.putImageData(atlas, 0, 0);
  return canvas;
}

/// Grows painted texels into the empty gaps around them so filtering doesn't pull in black at seams.
function dilate(image, passes) {
  const { data } = image;
  for (let pass = 0; pass < passes; pass++) {
    const copy = new Uint8ClampedArray(data);
    for (let y = 0; y < ATLAS; y++) {
      for (let x = 0; x < ATLAS; x++) {
        const index = (y * ATLAS + x) * 4;
        if (copy[index + 3]) continue;
        for (const [dx, dy] of [[1, 0], [-1, 0], [0, 1], [0, -1]]) {
          const nx = x + dx, ny = y + dy;
          if (nx < 0 || ny < 0 || nx >= ATLAS || ny >= ATLAS) continue;
          const neighbor = (ny * ATLAS + nx) * 4;
          if (!copy[neighbor + 3]) continue;
          data.set(copy.subarray(neighbor, neighbor + 4), index);
          break;
        }
      }
    }
  }
}

/// The finished chameleon: one skinned mesh with the baked texture, ready for GLTFExporter.
export function chameleonScene(mannequin, texture) {
  const geometry = mergeGeometries(mannequin.parts.map(part => part.geometry), false);
  const map = new THREE.CanvasTexture(texture);
  map.flipY = false;
  map.colorSpace = THREE.SRGBColorSpace;
  const mesh = new THREE.SkinnedMesh(geometry, new THREE.MeshStandardMaterial({ map, roughness: 0.6 }));
  mesh.name = 'Chameleon';
  mesh.add(mannequin.root);
  mesh.bind(new THREE.Skeleton(mannequin.boneList));
  const scene = new THREE.Scene();
  scene.add(mesh);
  return scene;
}
