import * as THREE from 'three';
import { mergeGeometries } from 'three/addons/utils/BufferGeometryUtils.js';

// A blocky, faceless Meccha-style mannequin, generated in code so it needs no model file.
// It faces +Z with its left side at +X, stands 1.75 m tall in an A-pose, and uses
// Mixamo bone names so the pose wheel (rig.js) works on it.

const HEIGHT = 1.75;
const ATLAS = 512;
const ARM_DROP = THREE.MathUtils.degToRad(40);

// Bone name, parent, world position in the rest pose.
function skeletonLayout() {
  const arm = new THREE.Vector3(Math.cos(ARM_DROP), -Math.sin(ARM_DROP), 0);
  const bones = [
    ['Hips', null, [0, 0.95, 0]], ['Spine', 'Hips', [0, 1.05, 0]], ['Spine1', 'Spine', [0, 1.17, 0]],
    ['Spine2', 'Spine1', [0, 1.29, 0]], ['Neck', 'Spine2', [0, 1.46, 0]], ['Head', 'Neck', [0, 1.52, 0]],
    ['HeadTop_End', 'Head', [0, HEIGHT, 0]]
  ];
  for (const [side, sign] of [['Left', 1], ['Right', -1]]) {
    const shoulder = new THREE.Vector3(sign * 0.21, 1.42, 0);
    const along = arm.clone().setX(arm.x * sign);
    const elbow = shoulder.clone().addScaledVector(along, 0.29);
    const wrist = elbow.clone().addScaledVector(along, 0.26);
    const fingers = wrist.clone().addScaledVector(along, 0.16);
    bones.push(
      [side + 'Shoulder', 'Spine2', [sign * 0.08, 1.42, 0]], [side + 'Arm', side + 'Shoulder', shoulder.toArray()],
      [side + 'ForeArm', side + 'Arm', elbow.toArray()], [side + 'Hand', side + 'ForeArm', wrist.toArray()],
      [side + 'HandMiddle1', side + 'Hand', fingers.toArray()],
      [side + 'UpLeg', 'Hips', [sign * 0.1, 0.9, 0]], [side + 'Leg', side + 'UpLeg', [sign * 0.1, 0.49, 0]],
      [side + 'Foot', side + 'Leg', [sign * 0.1, 0.08, 0]], [side + 'ToeBase', side + 'Foot', [sign * 0.1, 0.03, 0.15]],
      [side + 'Toe_End', side + 'ToeBase', [sign * 0.1, 0.03, 0.2]]
    );
  }
  return bones;
}

// Each part is a box riding rigidly on one bone: [bone, from, to, width, depth].
// Torso parts run vertically; limbs run from one bone to the next.
function partLayout(world) {
  const p = name => world.get(name);
  const parts = [
    ['Hips', [0, 0.86, 0], [0, 1.05, 0], 0.34, 0.21],
    ['Spine1', [0, 1.05, 0], [0, 1.25, 0], 0.31, 0.19],
    ['Spine2', [0, 1.25, 0], [0, 1.47, 0], 0.4, 0.22],
    ['Neck', [0, 1.45, 0], [0, 1.53, 0], 0.11, 0.11],
    ['Head', [0, 1.52, 0], [0, HEIGHT, 0], 0.2, 0.22]
  ];
  for (const side of ['Left', 'Right']) {
    parts.push(
      [side + 'Arm', p(side + 'Arm'), p(side + 'ForeArm'), 0.1, 0.1],
      [side + 'ForeArm', p(side + 'ForeArm'), p(side + 'Hand'), 0.085, 0.085],
      [side + 'Hand', p(side + 'Hand'), p(side + 'HandMiddle1'), 0.09, 0.04],
      [side + 'UpLeg', p(side + 'UpLeg'), p(side + 'Leg'), 0.15, 0.16],
      [side + 'Leg', p(side + 'Leg'), p(side + 'Foot'), 0.115, 0.12],
      [side + 'Foot', [p(side + 'Foot').x, 0.045, -0.05], [p(side + 'Foot').x, 0.045, 0.17], 0.1, 0.09]
    );
  }
  return parts.map(([bone, from, to, width, depth]) => ({
    bone, from: new THREE.Vector3(...from), to: new THREE.Vector3(...to), width, depth
  }));
}

/// Builds the skinned mannequin. Returns the mesh plus each box face's corners for baking.
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

  const geometries = [];
  const faces = [];
  const boxes = [];
  for (const part of partLayout(world)) {
    const axis = part.to.clone().sub(part.from);
    const length = axis.length();
    // Feet lie along Z; everything else is a box stood along its segment.
    const geometry = new THREE.BoxGeometry(part.width, length, part.depth);
    const rotation = new THREE.Quaternion().setFromUnitVectors(new THREE.Vector3(0, 1, 0), axis.clone().normalize());
    const center = part.from.clone().add(part.to).multiplyScalar(0.5);
    geometry.applyQuaternion(rotation);
    geometry.translate(center.x, center.y, center.z);
    const boneIndex = boneList.indexOf(bones.get(part.bone));
    const count = geometry.attributes.position.count;
    geometry.setAttribute('skinIndex', new THREE.Uint16BufferAttribute(new Array(count).fill(0).flatMap(() => [boneIndex, 0, 0, 0]), 4));
    geometry.setAttribute('skinWeight', new THREE.Float32BufferAttribute(new Array(count).fill(0).flatMap(() => [1, 0, 0, 0]), 4));
    boxes.push({ part: part.bone, center, rotation, half: new THREE.Vector3(part.width / 2, length / 2, part.depth / 2) });

    // BoxGeometry has 4 vertices per face; remember each face's corners by their UV.
    const positions = geometry.attributes.position;
    const uvs = geometry.attributes.uv;
    const normals = geometry.attributes.normal;
    for (let face = 0; face < 6; face++) {
      const corner = {};
      for (let vertex = face * 4; vertex < face * 4 + 4; vertex++) {
        corner[`${uvs.getX(vertex)},${uvs.getY(vertex)}`] = new THREE.Vector3().fromBufferAttribute(positions, vertex);
      }
      faces.push({
        geometryIndex: geometries.length, first: face * 4, part: part.bone,
        normal: new THREE.Vector3().fromBufferAttribute(normals, face * 4),
        p00: corner['0,0'], p10: corner['1,0'], p01: corner['0,1'], p11: corner['1,1']
      });
    }
    geometries.push(geometry);
  }
  packFaces(faces);
  // Point each face's UVs at its own patch of the texture.
  for (const face of faces) {
    const uvs = geometries[face.geometryIndex].attributes.uv;
    for (let vertex = face.first; vertex < face.first + 4; vertex++) {
      uvs.setXY(vertex, (face.rect.x + uvs.getX(vertex) * face.rect.w) / ATLAS, (face.rect.y + uvs.getY(vertex) * face.rect.h) / ATLAS);
    }
  }
  return { geometries, faces, boxes, boneList, root: bones.get('Hips') };
}

/// Shelf-packs every face into the atlas at the largest uniform texels-per-metre that fits.
function packFaces(faces) {
  for (const face of faces) {
    face.lengthU = face.p10.distanceTo(face.p00);
    face.lengthV = face.p01.distanceTo(face.p00);
  }
  const order = [...faces].sort((a, b) => b.lengthV - a.lengthV);
  const fits = scale => {
    let x = 0, y = 0, row = 0;
    for (const face of order) {
      const w = Math.max(2, Math.floor(face.lengthU * scale)), h = Math.max(2, Math.floor(face.lengthV * scale));
      if (x + w + 2 > ATLAS) { x = 0; y += row + 2; row = 0; }
      if (y + h + 2 > ATLAS || w + 2 > ATLAS) return false;
      face.rect = { x: x + 1, y: y + 1, w, h };
      x += w + 2; row = Math.max(row, h);
    }
    return true;
  };
  let low = 1, high = 4000;
  for (let step = 0; step < 24; step++) { const middle = (low + high) / 2; if (fits(middle)) low = middle; else high = middle; }
  fits(low);
}

/// Ray (origin, direction) against an oriented box; true when it hits in front of the origin.
function rayHitsBox(origin, direction, box) {
  const inverse = box.rotation.clone().invert();
  const o = origin.clone().sub(box.center).applyQuaternion(inverse);
  const d = direction.clone().applyQuaternion(inverse);
  let near = -Infinity, far = Infinity;
  for (const axis of ['x', 'y', 'z']) {
    if (Math.abs(d[axis]) < 1e-9) { if (Math.abs(o[axis]) > box.half[axis]) return false; continue; }
    const a = (-box.half[axis] - o[axis]) / d[axis], b = (box.half[axis] - o[axis]) / d[axis];
    near = Math.max(near, Math.min(a, b)); far = Math.min(far, Math.max(a, b));
  }
  return far >= Math.max(near, 0.001);
}

/// Projects the turnaround photos onto the mannequin's texture.
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
  const point = new THREE.Vector3(), start = new THREE.Vector3();
  for (const face of mannequin.faces) {
    const others = mannequin.boxes.filter(box => box.part !== face.part);
    const skipFront = faceless && face.part === 'Head' && face.normal.z > 0.9;
    for (let ty = 0; ty < face.rect.h; ty++) {
      for (let tx = 0; tx < face.rect.w; tx++) {
        const u = (tx + 0.5) / face.rect.w, v = (ty + 0.5) / face.rect.h;
        point.copy(face.p00).multiplyScalar((1 - u) * (1 - v)).addScaledVector(face.p10, u * (1 - v))
          .addScaledVector(face.p01, (1 - u) * v).addScaledVector(face.p11, u * v);
        let red = 0, green = 0, blue = 0, total = 0;
        if (!skipFront) {
          for (const view of samples) {
            const facing = face.normal.dot(view.toCamera);
            if (facing < 0.2) continue;
            start.copy(point).addScaledVector(face.normal, 0.003);
            if (others.some(box => rayHitsBox(start, view.toCamera, box))) continue;
            // Orthographic: head-to-feet of the mannequin spans the crop's height.
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
        }
        const index = ((face.rect.y + ty) * ATLAS + face.rect.x + tx) * 4;
        // Anything no photo saw stays mannequin white.
        atlas.data[index] = total ? red / total : 255;
        atlas.data[index + 1] = total ? green / total : 255;
        atlas.data[index + 2] = total ? blue / total : 255;
        atlas.data[index + 3] = 255;
      }
    }
  }
  dilate(atlas, 2);
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
  const geometry = mergeGeometries(mannequin.geometries, false);
  const map = new THREE.CanvasTexture(texture);
  map.flipY = false;
  map.colorSpace = THREE.SRGBColorSpace;
  const mesh = new THREE.SkinnedMesh(geometry, new THREE.MeshStandardMaterial({ map, roughness: 0.85 }));
  mesh.name = 'Chameleon';
  mesh.add(mannequin.root);
  mesh.bind(new THREE.Skeleton(mannequin.boneList));
  const scene = new THREE.Scene();
  scene.add(mesh);
  return scene;
}
