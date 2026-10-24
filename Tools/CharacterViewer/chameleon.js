import * as THREE from 'three';

// Maps four photos of a player (front, right side, back, left side) onto the chameleon base body:
// BlueMan's MECCHA CHAMELEON Player rig (CC BY 4.0), prepared by Tools/ChameleonModel/prepare.mjs
// into one smooth skinned mesh with its own UVs and Mixamo bone names. The body faces +Z with its
// left side at +X.
//
// Like Minecraft "skin from photo" tools, it works part by part: each limb, the torso and the head
// take their own strip of the photo, stretched along the limb from joint to joint, so a different
// body shape still lands in the right place. Anything no photo covers gets that part's main color,
// never white.

const ATLAS = 1024;
const BINS = 24;
// Players stand with their arms out a little; the base rests in a T-pose.
const ARM_DROP = THREE.MathUtils.degToRad(40);

// Body part → [model joint at its start, model joint at its end, photo keypoint at start, at end,
// how far past the end the part runs (hands, feet), widest the photo strip may be as a share of
// its length].
const PARTS = {
  torso: ['Hips', 'Neck', 'hips', 'neck', 0.15, 0.75],
  head: ['Neck', 'HeadTop_End', 'neck', 'headTop', 0.1, 0.6],
  leftUpperArm: ['LeftArm', 'LeftForeArm', 'leftShoulder', 'leftElbow', 0.1, 0.45],
  leftForearm: ['LeftForeArm', 'LeftHand', 'leftElbow', 'leftWrist', 0.45, 0.45],
  rightUpperArm: ['RightArm', 'RightForeArm', 'rightShoulder', 'rightElbow', 0.1, 0.45],
  rightForearm: ['RightForeArm', 'RightHand', 'rightElbow', 'rightWrist', 0.45, 0.45],
  leftThigh: ['LeftUpLeg', 'LeftLeg', 'leftHip', 'leftKnee', 0.1, 0.4],
  leftShin: ['LeftLeg', 'LeftFoot', 'leftKnee', 'leftAnkle', 0.35, 0.4],
  rightThigh: ['RightUpLeg', 'RightLeg', 'rightHip', 'rightKnee', 0.1, 0.4],
  rightShin: ['RightLeg', 'RightFoot', 'rightKnee', 'rightAnkle', 0.35, 0.4]
};

// Which part each bone's skin belongs to.
const PART_OF_BONE = {
  _rootJoint: 'torso', Hips: 'torso', Spine: 'torso', Spine1: 'torso', Spine2: 'torso', Chest: 'torso', UpperChest: 'torso',
  Neck: 'head', Head: 'head', HeadTop_End: 'head',
  LeftArm: 'leftUpperArm', LeftForeArm: 'leftForearm', LeftHand: 'leftForearm',
  RightArm: 'rightUpperArm', RightForeArm: 'rightForearm', RightHand: 'rightForearm',
  LeftUpLeg: 'leftThigh', LeftLeg: 'leftShin', LeftFoot: 'leftShin',
  RightUpLeg: 'rightThigh', RightLeg: 'rightShin', RightFoot: 'rightShin'
};

/// Drops the arms from the T-pose to the photos' A-pose, in world space.
function armsDown(character) {
  character.updateMatrixWorld(true);
  for (const [name, sign] of [['LeftArm', -1], ['RightArm', 1]]) {
    let bone;
    character.traverse(node => { if (node.isBone && node.name === name) bone = node; });
    if (!bone) continue;
    const turn = new THREE.Quaternion().setFromAxisAngle(new THREE.Vector3(0, 0, 1), sign * ARM_DROP);
    const world = bone.getWorldQuaternion(new THREE.Quaternion());
    const parent = bone.parent.getWorldQuaternion(new THREE.Quaternion());
    bone.quaternion.copy(parent.invert().multiply(turn.multiply(world)));
  }
  character.updateMatrixWorld(true);
}

/// Posed world positions and smooth normals of every vertex, plus the triangles.
function posedSurface(mesh) {
  mesh.skeleton.update();
  const count = mesh.geometry.attributes.position.count;
  const positions = new Float32Array(count * 3);
  const vertex = new THREE.Vector3();
  for (let index = 0; index < count; index++) {
    mesh.getVertexPosition(index, vertex).applyMatrix4(mesh.matrixWorld);
    vertex.toArray(positions, index * 3);
  }
  const triangles = mesh.geometry.index.array;
  const normals = new Float32Array(count * 3);
  const a = new THREE.Vector3(), b = new THREE.Vector3(), c = new THREE.Vector3();
  for (let t = 0; t < triangles.length; t += 3) {
    a.fromArray(positions, triangles[t] * 3); b.fromArray(positions, triangles[t + 1] * 3); c.fromArray(positions, triangles[t + 2] * 3);
    const n = b.clone().sub(a).cross(c.clone().sub(a));
    for (const v of [triangles[t], triangles[t + 1], triangles[t + 2]]) {
      normals[v * 3] += n.x; normals[v * 3 + 1] += n.y; normals[v * 3 + 2] += n.z;
    }
  }
  for (let v = 0; v < normals.length; v += 3) {
    const length = Math.hypot(normals[v], normals[v + 1], normals[v + 2]) || 1;
    normals[v] /= length; normals[v + 1] /= length; normals[v + 2] /= length;
  }
  return { positions, normals, triangles };
}

/// Which part each vertex belongs to, from its strongest bone weight.
function vertexParts(mesh) {
  const joints = mesh.geometry.attributes.skinIndex, weights = mesh.geometry.attributes.skinWeight;
  const parts = new Array(joints.count);
  for (let v = 0; v < joints.count; v++) {
    let best = 0;
    for (let k = 1; k < 4; k++) if (weights.getComponent(v, k) > weights.getComponent(v, best)) best = k;
    parts[v] = PART_OF_BONE[mesh.skeleton.bones[joints.getComponent(v, best)]?.name] ?? 'torso';
  }
  return parts;
}

/// Closest point on segment a–b to p, and how far along (0 at a, 1 at b; not clamped).
function alongSegment(p, a, b) {
  const ab = b.clone().sub(a);
  const t = p.clone().sub(a).dot(ab) / Math.max(ab.lengthSq(), 1e-9);
  return { t, point: a.clone().addScaledVector(ab, THREE.MathUtils.clamp(t, 0, 1)) };
}

/// A 2D frame along an axis in screen space (x right, y up): how far along, and how far to the side.
function axisCoordinates(point, a, b) {
  const dx = b.x - a.x, dy = b.y - a.y, length = Math.hypot(dx, dy) || 1e-9;
  const ux = dx / length, uy = dy / length;
  const rx = point.x - a.x, ry = point.y - a.y;
  return { t: (rx * ux + ry * uy) / length, side: rx * -uy + ry * ux, length, ux, uy };
}

/// Reads a photo: its pixels, plus named keypoints in pixels with y up (so they match the model's
/// screen space). The person's left and right are sorted by where they must be from this side.
function preparePhoto(view) {
  const canvas = document.createElement('canvas');
  canvas.width = view.image.width; canvas.height = view.image.height;
  const context = canvas.getContext('2d', { willReadFrequently: true });
  context.drawImage(view.image, 0, 0);
  const pixels = context.getImageData(0, 0, canvas.width, canvas.height).data;
  const width = canvas.width, height = canvas.height;
  const opaque = (x, y) => x >= 0 && y >= 0 && x < width && y < height && pixels[(Math.round(height - 1 - y) * width + Math.round(x)) * 4 + 3] >= 128;
  const points = {};
  for (const [name, [x, y, confidence]] of Object.entries(view.keypoints ?? {})) {
    if (confidence >= 0.2) points[name] = new THREE.Vector2(x, height - y);
  }
  const yaw = ((view.yaw % 360) + 360) % 360;
  const facingCamera = yaw < 45 || yaw > 315, backToCamera = yaw > 135 && yaw < 225;
  // From the front the person's left is on the image's right; from behind it's on the left.
  // Vision can get this backwards when the back is turned, so sort by position.
  if (facingCamera || backToCamera) {
    for (const joint of ['Shoulder', 'Elbow', 'Wrist', 'Hip', 'Knee', 'Ankle']) {
      const left = points['left' + joint], right = points['right' + joint];
      if (left && right && (left.x < right.x) === facingCamera) [points['left' + joint], points['right' + joint]] = [right, left];
    }
  }
  if (!points.neck && points.leftShoulder && points.rightShoulder) points.neck = points.leftShoulder.clone().add(points.rightShoulder).multiplyScalar(0.5);
  if (!points.hips) {
    if (points.leftHip && points.rightHip) points.hips = points.leftHip.clone().add(points.rightHip).multiplyScalar(0.5);
    else points.hips = points.root ?? points.leftHip ?? points.rightHip;
  }
  // The top of the head: straight up from the neck to the top of the cutout.
  if (points.neck) {
    let y = points.neck.y;
    while (y < height && opaque(points.neck.x, y + 1)) y++;
    points.headTop = new THREE.Vector2(points.neck.x, y);
  }
  const turn = THREE.MathUtils.degToRad(yaw);
  return {
    pixels, width, height, opaque, points, yaw,
    toCamera: new THREE.Vector3(Math.sin(turn), 0, Math.cos(turn)), right: new THREE.Vector3(Math.cos(turn), 0, -Math.sin(turn)),
    // From the side, the far limbs and the torso are hidden behind the near arm and leg.
    uses: part => facingCamera || backToCamera || part === 'head'
      || (yaw < 180 ? part.startsWith('left') : part.startsWith('right'))
  };
}

/// Maps every vertex of one part into one photo: along its joint-to-joint axis, and across it in
/// proportion to the part's width at that point, in the model and in the photo's cutout.
function strip(part, view, model, partVertices, positions) {
  const [startJoint, endJoint, startKey, endKey, overrun, maxWidth] = PARTS[part];
  const a = view.points[startKey], b = view.points[endKey];
  const A3 = model.joints[startJoint], B3 = model.joints[endJoint];
  if (!a || !b || !A3 || !B3 || a.distanceTo(b) < 4) return null;
  const screen = p => new THREE.Vector2(p.dot(view.right), p.y);
  const A = screen(A3), B = screen(B3);

  // The model part's half-width along its length, measured from its vertices.
  const modelWidth = new Float32Array(BINS).fill(0);
  const bin = t => THREE.MathUtils.clamp(Math.floor((t + 0.2) / (1.4 + overrun) * BINS), 0, BINS - 1);
  const point = new THREE.Vector3();
  for (const v of partVertices) {
    point.fromArray(positions, v * 3);
    const c = axisCoordinates(screen(point), A, B);
    const index = bin(c.t);
    modelWidth[index] = Math.max(modelWidth[index], Math.abs(c.side));
  }
  // The photo's cutout: how far it reaches to either side of the axis at each step along it.
  const axis = axisCoordinates(b, a, b);
  const photoLeft = new Float32Array(BINS), photoRight = new Float32Array(BINS);
  let limit = axis.length * maxWidth;
  // The torso's cutout runs into the arms at shoulder height; stop at about half the shoulders' span.
  const { leftShoulder, rightShoulder, leftHip, rightHip } = view.points;
  if (part === 'torso' && leftShoulder && rightShoulder) {
    limit = Math.min(limit, 0.6 * Math.max(leftShoulder.distanceTo(rightShoulder), leftHip && rightHip ? leftHip.distanceTo(rightHip) * 1.3 : 0));
  }
  for (let index = 0; index < BINS; index++) {
    const t = (index + 0.5) / BINS * (1.4 + overrun) - 0.2;
    const cx = a.x + (b.x - a.x) * t, cy = a.y + (b.y - a.y) * t;
    let left = 0, right = 0;
    // "Right of the axis" is the +side direction (-uy, ux) from axisCoordinates; left is the opposite.
    while (left < limit && view.opaque(cx + axis.uy * (left + 1), cy - axis.ux * (left + 1))) left++;
    while (right < limit && view.opaque(cx - axis.uy * (right + 1), cy + axis.ux * (right + 1))) right++;
    photoLeft[index] = left; photoRight[index] = right;
  }
  return { A, B, a, b, axis, modelWidth, photoLeft, photoRight, bin, screen };
}

/// Projects the four photos onto the body's texture and returns the body wearing it.
/// Each view: a person cutout cropped head-to-feet, how far they'd turned to their right (0, 90,
/// 180, 270), and Vision body keypoints in crop pixels from the top-left: { name: [x, y, confidence] }.
export function bakeOnto(character, views, { faceless = true } = {}) {
  let mesh;
  character.traverse(node => { if (node.isSkinnedMesh && !mesh) mesh = node; });
  const rest = mesh.skeleton.bones.map(bone => bone.quaternion.clone());
  armsDown(character);
  const { positions, normals, triangles } = posedSurface(mesh);
  const parts = vertexParts(mesh);
  const joints = {};
  for (const bone of mesh.skeleton.bones) joints[bone.name] = bone.getWorldPosition(new THREE.Vector3());
  const point = new THREE.Vector3(), normal = new THREE.Vector3();

  // The rig skins the sides of the chest to the upper arms and the hips to the thighs. Anything on
  // the body's side of the shoulder or hip joint is torso.
  for (let v = 0; v < parts.length; v++) {
    const part = parts[v];
    if (!/UpperArm|Thigh/.test(part)) continue;
    const [start, end] = PARTS[part];
    point.fromArray(positions, v * 3);
    if (alongSegment(point, joints[start], joints[end]).t < 0.12) parts[v] = 'torso';
  }

  // Point normals outward, away from each part's axis (the source mesh's winding isn't reliable).
  for (let v = 0; v < parts.length; v++) {
    const [start, end] = PARTS[parts[v]];
    if (!joints[start] || !joints[end]) continue;
    point.fromArray(positions, v * 3); normal.fromArray(normals, v * 3);
    if (normal.dot(point.clone().sub(alongSegment(point, joints[start], joints[end]).point)) < 0) {
      normals[v * 3] *= -1; normals[v * 3 + 1] *= -1; normals[v * 3 + 2] *= -1;
    }
  }

  const photos = views.map(preparePhoto);
  const verticesOf = {};
  parts.forEach((part, v) => (verticesOf[part] ??= []).push(v));
  const model = { joints };
  const strips = photos.map(view => Object.fromEntries(Object.keys(PARTS)
    .filter(part => view.uses(part) && verticesOf[part])
    .map(part => [part, strip(part, view, model, verticesOf[part], positions)])));

  const sample = (view, x, y) => {
    const px = Math.round(x), py = Math.round(view.height - 1 - y);
    if (px < 0 || py < 0 || px >= view.width || py >= view.height) return null;
    const index = (py * view.width + px) * 4;
    return view.pixels[index + 3] >= 128 ? [view.pixels[index], view.pixels[index + 1], view.pixels[index + 2]] : null;
  };
  const screenPoint = new THREE.Vector2();
  // What the photos show at one spot of one part, blended by how squarely each photo saw it.
  const colorFor = (part, point, normal) => {
    let r = 0, g = 0, b = 0, total = 0;
    photos.forEach((view, index) => {
      const s = strips[index][part];
      if (!s) return;
      const facing = normal.dot(view.toCamera);
      if (facing < 0.2) return;
      screenPoint.set(point.dot(view.right), point.y);
      const c = axisCoordinates(screenPoint, s.A, s.B);
      if (c.t < -0.2 || c.t > 1 + PARTS[part][4]) return;
      const k = s.bin(c.t);
      // Across the part, scaled into the photo strip by how far the cutout reaches on that side.
      const across = c.side / Math.max(s.modelWidth[k], 1e-6);
      const offset = across * (across < 0 ? s.photoLeft[k] : s.photoRight[k]);
      const cx = s.a.x + (s.b.x - s.a.x) * c.t, cy = s.a.y + (s.b.y - s.a.y) * c.t;
      const rgb = sample(view, cx - s.axis.uy * offset, cy + s.axis.ux * offset);
      if (!rgb) return;
      const weight = facing * facing;
      r += rgb[0] * weight; g += rgb[1] * weight; b += rgb[2] * weight; total += weight;
    });
    return total ? [r / total, g / total, b / total] : null;
  };

  const median = list => {
    if (!list?.length) return null;
    return [0, 1, 2].map(c => list.map(rgb => rgb[c]).sort((x, y) => x - y)[Math.floor(list.length / 2)]);
  };
  // Skin from just above the nose in the front photo, for a faceless face.
  const front = photos.find(view => view.yaw < 45 || view.yaw > 315);
  let skin = null;
  if (front?.points.nose) {
    const around = [];
    for (let dy = -6; dy <= 6; dy += 2) for (let dx = -6; dx <= 6; dx += 2) {
      const rgb = sample(front, front.points.nose.x + dx, front.points.nose.y + dy + 8);
      if (rgb) around.push(rgb);
    }
    skin = median(around);
  }
  skin ??= [224, 182, 150];

  // Paint the texture texel by texel. Texels no photo covers are marked and filled afterwards with
  // their part's main color.
  const canvas = document.createElement('canvas');
  canvas.width = canvas.height = ATLAS;
  const context = canvas.getContext('2d', { willReadFrequently: true });
  const atlas = context.createImageData(ATLAS, ATLAS);
  const texelPart = new Array(ATLAS * ATLAS);
  const partSamples = {};
  const uv = mesh.geometry.attributes.uv;
  const ua = new THREE.Vector2(), ub = new THREE.Vector2(), uc = new THREE.Vector2();
  for (let t = 0; t < triangles.length; t += 3) {
    const [i, j, k] = [triangles[t], triangles[t + 1], triangles[t + 2]];
    const part = parts[i];
    ua.fromBufferAttribute(uv, i).multiplyScalar(ATLAS); ub.fromBufferAttribute(uv, j).multiplyScalar(ATLAS); uc.fromBufferAttribute(uv, k).multiplyScalar(ATLAS);
    const area = (ub.x - ua.x) * (uc.y - ua.y) - (uc.x - ua.x) * (ub.y - ua.y);
    if (Math.abs(area) < 1e-9) continue;
    const minX = Math.max(0, Math.floor(Math.min(ua.x, ub.x, uc.x))), maxX = Math.min(ATLAS - 1, Math.ceil(Math.max(ua.x, ub.x, uc.x)));
    const minY = Math.max(0, Math.floor(Math.min(ua.y, ub.y, uc.y))), maxY = Math.min(ATLAS - 1, Math.ceil(Math.max(ua.y, ub.y, uc.y)));
    for (let y = minY; y <= maxY; y++) {
      for (let x = minX; x <= maxX; x++) {
        const px = x + 0.5, py = y + 0.5;
        const w1 = ((ub.x - px) * (uc.y - py) - (uc.x - px) * (ub.y - py)) / area;
        const w2 = ((uc.x - px) * (ua.y - py) - (ua.x - px) * (uc.y - py)) / area;
        const w3 = 1 - w1 - w2;
        if (w1 < -0.02 || w2 < -0.02 || w3 < -0.02) continue;
        point.set(0, 0, 0); normal.set(0, 0, 0);
        for (const [vertex, weight] of [[i, w1], [j, w2], [k, w3]]) {
          point.x += positions[vertex * 3] * weight; point.y += positions[vertex * 3 + 1] * weight; point.z += positions[vertex * 3 + 2] * weight;
          normal.x += normals[vertex * 3] * weight; normal.y += normals[vertex * 3 + 1] * weight; normal.z += normals[vertex * 3 + 2] * weight;
        }
        normal.normalize();
        const texel = y * ATLAS + x;
        // Faceless: the front of the head is plain skin.
        const rgb = faceless && part === 'head' && normal.z > 0.3 && point.y > joints.Neck.y ? skin : colorFor(part, point, normal);
        texelPart[texel] = part;
        if (rgb) {
          atlas.data.set([rgb[0], rgb[1], rgb[2], 255], texel * 4);
          if ((x + y) % 7 === 0 && rgb !== skin) (partSamples[part] ??= []).push(rgb);
        }
      }
    }
  }

  // Each part's main color (per-channel median). Limbs without photos borrow from their other
  // half or the other side, then the torso; nothing stays white.
  const mainColor = {};
  for (const part of Object.keys(PARTS)) mainColor[part] = median(partSamples[part]);
  const borrow = { leftForearm: 'leftUpperArm', leftUpperArm: 'leftForearm', rightForearm: 'rightUpperArm', rightUpperArm: 'rightForearm',
    leftShin: 'leftThigh', leftThigh: 'leftShin', rightShin: 'rightThigh', rightThigh: 'rightShin' };
  for (const part of Object.keys(PARTS)) {
    mainColor[part] ??= mainColor[borrow[part]] ?? mainColor[part.replace('left', 'right')] ?? mainColor[part.replace('right', 'left')];
  }
  for (const part of Object.keys(PARTS)) mainColor[part] ??= mainColor.torso ?? [128, 128, 128];
  for (let texel = 0; texel < texelPart.length; texel++) {
    const part = texelPart[texel];
    if (part && !atlas.data[texel * 4 + 3]) atlas.data.set([...mainColor[part], 255], texel * 4);
  }
  dilate(atlas, 4);
  context.putImageData(atlas, 0, 0);

  // Back to the rest pose, then wear the new texture.
  mesh.skeleton.bones.forEach((bone, index) => bone.quaternion.copy(rest[index]));
  character.updateMatrixWorld(true);
  const map = new THREE.CanvasTexture(canvas);
  map.flipY = false;
  map.colorSpace = THREE.SRGBColorSpace;
  mesh.material = new THREE.MeshStandardMaterial({ map, roughness: 0.6, side: THREE.DoubleSide });
  return character;
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
