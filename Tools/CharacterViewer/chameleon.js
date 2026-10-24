import * as THREE from 'three';

// Maps a player's 360° turnaround onto the chameleon base body: BlueMan's MECCHA CHAMELEON
// Player rig (CC BY 4.0), prepared by Tools/ChameleonModel/prepare.mjs into one smooth skinned
// mesh with its own UVs and Mixamo bone names. The body faces +Z with its left side at +X.

const ATLAS = 1024;
const DEPTH_SIZE = 256;
// Players spin with their arms out a little; the base rests in a T-pose.
const ARM_DROP = THREE.MathUtils.degToRad(40);

/// Drops the arms from the T-pose to the turnaround's A-pose, in world space.
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

/// Posed world positions and normals of every vertex, plus the triangles.
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
  // Normals from the posed triangles, since skinning moved them.
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

/// For one view: an orthographic depth buffer of the body, so we know which surface the camera sees.
function depthBuffer(surface, view, frame) {
  const depth = new Float32Array(DEPTH_SIZE * DEPTH_SIZE).fill(-Infinity);
  const { positions, triangles } = surface;
  const project = index => {
    const x = positions[index * 3], y = positions[index * 3 + 1], z = positions[index * 3 + 2];
    const across = x * view.right.x + z * view.right.z, toward = x * view.toCamera.x + z * view.toCamera.z;
    return [(across - frame.left) / frame.size * DEPTH_SIZE, (frame.top - y) / frame.size * DEPTH_SIZE, toward];
  };
  for (let t = 0; t < triangles.length; t += 3) {
    const [p, q, r] = [project(triangles[t]), project(triangles[t + 1]), project(triangles[t + 2])];
    const area = (q[0] - p[0]) * (r[1] - p[1]) - (r[0] - p[0]) * (q[1] - p[1]);
    if (Math.abs(area) < 1e-9) continue;
    const minX = Math.max(0, Math.floor(Math.min(p[0], q[0], r[0]))), maxX = Math.min(DEPTH_SIZE - 1, Math.ceil(Math.max(p[0], q[0], r[0])));
    const minY = Math.max(0, Math.floor(Math.min(p[1], q[1], r[1]))), maxY = Math.min(DEPTH_SIZE - 1, Math.ceil(Math.max(p[1], q[1], r[1])));
    for (let y = minY; y <= maxY; y++) {
      for (let x = minX; x <= maxX; x++) {
        const px = x + 0.5, py = y + 0.5;
        const w1 = ((q[0] - px) * (r[1] - py) - (r[0] - px) * (q[1] - py)) / area;
        const w2 = ((r[0] - px) * (p[1] - py) - (p[0] - px) * (r[1] - py)) / area;
        const w3 = 1 - w1 - w2;
        if (w1 < 0 || w2 < 0 || w3 < 0) continue;
        const z = w1 * p[2] + w2 * q[2] + w3 * r[2];
        const cell = y * DEPTH_SIZE + x;
        if (z > depth[cell]) depth[cell] = z;
      }
    }
  }
  return { depth, project };
}

/// Projects the turnaround photos onto the body's texture and returns it as a canvas.
/// Each view is a person cutout cropped head-to-feet, the turn in degrees (turning to their
/// right is positive), and where the hips are across the crop (0–1).
export function bakeOnto(character, views, { faceless = true } = {}) {
  let mesh;
  character.traverse(node => { if (node.isSkinnedMesh && !mesh) mesh = node; });
  const rest = mesh.skeleton.bones.map(bone => bone.quaternion.clone());
  armsDown(character);
  const surface = posedSurface(mesh);
  const { positions, normals, triangles } = surface;

  let minY = Infinity, maxY = -Infinity, extent = 0;
  for (let v = 0; v < positions.length; v += 3) {
    minY = Math.min(minY, positions[v + 1]); maxY = Math.max(maxY, positions[v + 1]);
    extent = Math.max(extent, Math.abs(positions[v]), Math.abs(positions[v + 2]));
  }
  const height = maxY - minY;
  const frame = { left: -Math.max(extent, height / 2), top: maxY, size: Math.max(2 * extent, height) };
  // The face is the front half of everything above the neck.
  let neckY = minY + height * 0.8, headCenterZ = 0;
  character.traverse(node => {
    if (node.isBone && node.name === 'Neck') neckY = node.getWorldPosition(new THREE.Vector3()).y;
    if (node.isBone && node.name === 'Head') headCenterZ = node.getWorldPosition(new THREE.Vector3()).z;
  });

  const samples = views.map(view => {
    const image = document.createElement('canvas');
    image.width = view.image.width; image.height = view.image.height;
    const imageContext = image.getContext('2d', { willReadFrequently: true });
    imageContext.drawImage(view.image, 0, 0);
    const turn = THREE.MathUtils.degToRad(view.yaw);
    const sample = {
      pixels: imageContext.getImageData(0, 0, image.width, image.height).data, width: image.width, height: image.height,
      toCamera: new THREE.Vector3(Math.sin(turn), 0, Math.cos(turn)), right: new THREE.Vector3(Math.cos(turn), 0, -Math.sin(turn)),
      centerX: view.centerX ?? 0.5
    };
    Object.assign(sample, depthBuffer(surface, sample, frame));
    // Average brightness of the person, to even out frames that came out lighter or darker.
    let sum = 0, count = 0;
    for (let index = 0; index < sample.pixels.length; index += 16) {
      if (sample.pixels[index + 3] < 128) continue;
      sum += 0.299 * sample.pixels[index] + 0.587 * sample.pixels[index + 1] + 0.114 * sample.pixels[index + 2];
      count++;
    }
    sample.brightness = count ? sum / count : 128;
    return sample;
  });
  const meanBrightness = samples.reduce((total, view) => total + view.brightness, 0) / Math.max(samples.length, 1);
  for (const view of samples) view.gain = THREE.MathUtils.clamp(meanBrightness / Math.max(view.brightness, 1), 0.8, 1.25);

  // What one view sees at a point: [r, g, b, weight], or null.
  const look = (view, point, normal, checkDepth) => {
    // The source surface's winding isn't consistent, so judge by how square-on it is either way;
    // the depth buffer decides what is really in front.
    const facing = Math.abs(normal.dot(view.toCamera));
    if (facing < 0.15) return null;
    const across = point.dot(view.right), toward = point.dot(view.toCamera);
    const cellX = Math.floor((across - frame.left) / frame.size * DEPTH_SIZE), cellY = Math.floor((frame.top - point.y) / frame.size * DEPTH_SIZE);
    if (cellX < 0 || cellY < 0 || cellX >= DEPTH_SIZE || cellY >= DEPTH_SIZE) return null;
    // Hidden behind another part of the body from this side.
    if (checkDepth && toward < view.depth[cellY * DEPTH_SIZE + cellX] - height * 0.02) return null;
    // Orthographic: head-to-feet of the body spans the crop's height.
    const scale = view.height / height;
    const px = Math.round(view.centerX * view.width + across * scale);
    const py = Math.round((maxY - point.y) * scale);
    if (px < 0 || py < 0 || px >= view.width || py >= view.height) return null;
    const index = (py * view.width + px) * 4;
    if (view.pixels[index + 3] < 128) return null;
    return [view.pixels[index] * view.gain, view.pixels[index + 1] * view.gain, view.pixels[index + 2] * view.gain, facing ** 4];
  };

  const blend = looks => {
    let total = 0;
    const mean = [0, 0, 0];
    for (const [r, g, b, w] of looks) { mean[0] += r * w; mean[1] += g * w; mean[2] += b * w; total += w; }
    return total ? [mean[0] / total, mean[1] / total, mean[2] / total] : null;
  };

  const colorAt = (point, normal) => {
    if (faceless && point.y > neckY && point.z > headCenterZ) return null;
    let looks = samples.map(view => look(view, point, normal, true)).filter(Boolean);
    // Nothing clearly saw this spot (armpits, between the legs): take the best guess anyway.
    if (!looks.length) looks = samples.map(view => look(view, point, normal, false)).filter(Boolean);
    const mean = blend(looks);
    if (!mean || looks.length < 3) return mean;
    // Drop colors the other frames disagree with (blur, a hand passing in front).
    const agreeing = looks.filter(([r, g, b]) => Math.hypot(r - mean[0], g - mean[1], b - mean[2]) < 60);
    const kept = agreeing.reduce((sum, item) => sum + item[3], 0) / looks.reduce((sum, item) => sum + item[3], 0);
    return kept > 0.4 ? blend(agreeing) : mean;
  };

  const canvas = document.createElement('canvas');
  canvas.width = canvas.height = ATLAS;
  const context = canvas.getContext('2d', { willReadFrequently: true });
  const atlas = context.createImageData(ATLAS, ATLAS);
  const uv = mesh.geometry.attributes.uv;
  const ua = new THREE.Vector2(), ub = new THREE.Vector2(), uc = new THREE.Vector2();
  const point = new THREE.Vector3(), normal = new THREE.Vector3();
  for (let t = 0; t < triangles.length; t += 3) {
    const [i, j, k] = [triangles[t], triangles[t + 1], triangles[t + 2]];
    ua.fromBufferAttribute(uv, i).multiplyScalar(ATLAS); ub.fromBufferAttribute(uv, j).multiplyScalar(ATLAS); uc.fromBufferAttribute(uv, k).multiplyScalar(ATLAS);
    const area = (ub.x - ua.x) * (uc.y - ua.y) - (uc.x - ua.x) * (ub.y - ua.y);
    if (Math.abs(area) < 1e-9) continue;
    const minX = Math.max(0, Math.floor(Math.min(ua.x, ub.x, uc.x))), maxX = Math.min(ATLAS - 1, Math.ceil(Math.max(ua.x, ub.x, uc.x)));
    const minY = Math.max(0, Math.floor(Math.min(ua.y, ub.y, uc.y))), maxY2 = Math.min(ATLAS - 1, Math.ceil(Math.max(ua.y, ub.y, uc.y)));
    for (let y = minY; y <= maxY2; y++) {
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
        const rgb = colorAt(point, normal);
        const pixel = (y * ATLAS + x) * 4;
        // Anything no photo saw stays chameleon white.
        atlas.data[pixel] = rgb ? rgb[0] : 255;
        atlas.data[pixel + 1] = rgb ? rgb[1] : 255;
        atlas.data[pixel + 2] = rgb ? rgb[2] : 255;
        atlas.data[pixel + 3] = 255;
      }
    }
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
