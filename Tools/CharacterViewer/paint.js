import * as THREE from 'three';

const imageFromData = source => new Promise((resolve, reject) => {
  const image = new Image();
  image.onload = () => resolve(image);
  image.onerror = () => reject(new Error('Could not restore the saved paint.'));
  image.src = source;
});

export class SurfacePainter {
  constructor(character) {
    this.character = character;
    this.states = [];
    this.byMesh = new Map();
    this.undoStack = [];
    this.redoStack = [];
    this.stroke = null;
    let meshIndex = 0;
    character.traverse(mesh => {
      if (!mesh.isMesh || !mesh.geometry.attributes.uv) return;
      const materials = Array.isArray(mesh.material) ? mesh.material : [mesh.material];
      const states = materials.map((original, materialIndex) => {
        const material = original.clone();
        const canvas = document.createElement('canvas');
        canvas.width = canvas.height = 1024;
        const context = canvas.getContext('2d', { willReadFrequently: true });
        context.fillStyle = '#' + original.color.getHexString();
        context.fillRect(0, 0, 1024, 1024);
        if (original.map?.image) context.drawImage(original.map.image, 0, 0, 1024, 1024);
        const texture = new THREE.CanvasTexture(canvas);
        texture.flipY = false;
        texture.colorSpace = THREE.SRGBColorSpace;
        if (original.map) {
          texture.wrapS = original.map.wrapS;
          texture.wrapT = original.map.wrapT;
          texture.offset.copy(original.map.offset);
          texture.repeat.copy(original.map.repeat);
          texture.rotation = original.map.rotation;
        }
        material.color.set(0xffffff);
        material.map = texture;
        material.needsUpdate = true;
        const pixels = context.getImageData(0, 0, 1024, 1024);
        const state = { id: `${meshIndex}:${materialIndex}`, mesh, material, canvas, context, texture,
          pixels, packed: new Uint32Array(pixels.data.buffer), original: new Uint8ClampedArray(pixels.data), vertices: null };
        this.states.push(state);
        return state;
      });
      mesh.material = Array.isArray(mesh.material) ? states.map(state => state.material) : states[0].material;
      this.byMesh.set(mesh, states);
      meshIndex++;
    });
  }

  invalidate() { this.states.forEach(state => { state.vertices = null; }); }

  begin() {
    if (this.stroke) return;
    this.stroke = this.states.map(state => ({ state, before: new Uint32Array(state.packed) }));
  }

  end() {
    if (!this.stroke) return false;
    const entries = [];
    for (const { state, before } of this.stroke) {
      let count = 0;
      for (let index = 0; index < before.length; index++) if (before[index] !== state.packed[index]) count++;
      if (!count) continue;
      const indices = new Uint32Array(count);
      const previous = new Uint32Array(count);
      const next = new Uint32Array(count);
      let offset = 0;
      for (let index = 0; index < before.length; index++) {
        if (before[index] === state.packed[index]) continue;
        indices[offset] = index;
        previous[offset] = before[index];
        next[offset] = state.packed[index];
        offset++;
      }
      entries.push({ state, indices, previous, next });
    }
    this.stroke = null;
    if (!entries.length) return false;
    this.undoStack.push(entries);
    this.redoStack = [];
    const bytes = () => this.undoStack.reduce((total, stroke) => total + stroke.reduce((size, entry) => size + entry.indices.byteLength * 3, 0), 0);
    while (this.undoStack.length > 1 && bytes() > 24 * 1024 * 1024) this.undoStack.shift();
    return true;
  }

  refresh(state) {
    state.context.putImageData(state.pixels, 0, 0);
    state.texture.needsUpdate = true;
  }

  undo(redo = false) {
    this.end();
    const source = redo ? this.redoStack : this.undoStack;
    const target = redo ? this.undoStack : this.redoStack;
    const entries = source.pop();
    if (!entries) return false;
    for (const entry of entries) {
      const values = redo ? entry.next : entry.previous;
      entry.indices.forEach((index, offset) => { entry.state.packed[index] = values[offset]; });
      this.refresh(entry.state);
    }
    target.push(entries);
    return true;
  }

  vertices(state) {
    if (state.vertices) return state.vertices;
    const mesh = state.mesh;
    mesh.updateWorldMatrix(true, false);
    if (mesh.isSkinnedMesh) mesh.skeleton.update();
    const count = mesh.geometry.attributes.position.count;
    const vertices = new Float32Array(count * 3);
    const vertex = new THREE.Vector3();
    for (let index = 0; index < count; index++) {
      mesh.getVertexPosition(index, vertex).applyMatrix4(mesh.matrixWorld);
      vertex.toArray(vertices, index * 3);
    }
    state.vertices = vertices;
    return vertices;
  }

  stamp(hit, hex, radius, opacity, erase = false) {
    const states = this.byMesh.get(hit.object);
    const state = states?.[hit.face.materialIndex ?? 0];
    if (!state || !hit.uv) return false;
    this.begin();
    const mesh = hit.object;
    const geometry = mesh.geometry;
    const vertices = this.vertices(state);
    const indices = geometry.index;
    const count = indices ? indices.count : geometry.attributes.position.count;
    const uv = geometry.attributes.uv;
    const point = hit.point;
    const normal = hit.face.normal.clone().applyNormalMatrix(new THREE.Matrix3().getNormalMatrix(mesh.matrixWorld)).normalize();
    const color = new THREE.Color(hex).getHex();
    const channels = [(color >> 16) & 255, (color >> 8) & 255, color & 255];
    const triangle = new THREE.Triangle();
    const closest = new THREE.Vector3();
    const faceNormal = new THREE.Vector3();
    const coordinates = [new THREE.Vector2(), new THREE.Vector2(), new THREE.Vector2()];
    const radiusSquared = radius * radius;
    let changed = false;
    for (let offset = 0; offset < count; offset += 3) {
      if (Array.isArray(mesh.material)) {
        const group = geometry.groups.find(group => offset >= group.start && offset < group.start + group.count);
        if (group && states[group.materialIndex] !== state) continue;
      }
      const corners = [0, 1, 2].map(corner => indices ? indices.getX(offset + corner) : offset + corner);
      triangle.a.fromArray(vertices, corners[0] * 3);
      triangle.b.fromArray(vertices, corners[1] * 3);
      triangle.c.fromArray(vertices, corners[2] * 3);
      triangle.closestPointToPoint(point, closest);
      if (closest.distanceToSquared(point) > radiusSquared) continue;
      triangle.getNormal(faceNormal);
      if (faceNormal.dot(normal) < 0.15) continue;
      corners.forEach((corner, index) => {
        coordinates[index].fromBufferAttribute(uv, corner);
        state.texture.transformUv(coordinates[index]);
        coordinates[index].multiplyScalar(1024);
      });
      const [first, second, third] = coordinates;
      const denominator = (second.y - third.y) * (first.x - third.x) + (third.x - second.x) * (first.y - third.y);
      if (Math.abs(denominator) < 0.00001) continue;
      const minimumX = Math.max(0, Math.floor(Math.min(first.x, second.x, third.x)));
      const maximumX = Math.min(1023, Math.ceil(Math.max(first.x, second.x, third.x)));
      const minimumY = Math.max(0, Math.floor(Math.min(first.y, second.y, third.y)));
      const maximumY = Math.min(1023, Math.ceil(Math.max(first.y, second.y, third.y)));
      for (let pixelY = minimumY; pixelY <= maximumY; pixelY++) {
        for (let pixelX = minimumX; pixelX <= maximumX; pixelX++) {
          const firstWeight = ((second.y - third.y) * (pixelX + 0.5 - third.x) + (third.x - second.x) * (pixelY + 0.5 - third.y)) / denominator;
          const secondWeight = ((third.y - first.y) * (pixelX + 0.5 - third.x) + (first.x - third.x) * (pixelY + 0.5 - third.y)) / denominator;
          const thirdWeight = 1 - firstWeight - secondWeight;
          if (Math.min(firstWeight, secondWeight, thirdWeight) < -0.0001) continue;
          closest.copy(triangle.a).multiplyScalar(firstWeight).addScaledVector(triangle.b, secondWeight).addScaledVector(triangle.c, thirdWeight);
          const distance = closest.distanceTo(point);
          if (distance > radius) continue;
          const strength = opacity * Math.min(1, (1 - distance / radius) * 5);
          const pixel = (pixelY * 1024 + pixelX) * 4;
          for (let channel = 0; channel < 3; channel++) {
            const target = erase ? state.original[pixel + channel] : channels[channel];
            state.pixels.data[pixel + channel] = Math.round(state.pixels.data[pixel + channel] * (1 - strength) + target * strength);
          }
          state.pixels.data[pixel + 3] = 255;
          changed = true;
        }
      }
    }
    if (changed) this.refresh(state);
    return changed;
  }

  fill(hex = null) {
    this.begin();
    const color = hex == null ? null : parseInt(hex.replace('#', ''), 16);
    for (const state of this.states) {
      if (color == null) state.pixels.data.set(state.original);
      else for (let offset = 0; offset < state.pixels.data.length; offset += 4) {
        state.pixels.data[offset] = (color >> 16) & 255;
        state.pixels.data[offset + 1] = (color >> 8) & 255;
        state.pixels.data[offset + 2] = color & 255;
        state.pixels.data[offset + 3] = 255;
      }
      this.refresh(state);
    }
    this.end();
  }

  sample(hit) {
    const state = this.byMesh.get(hit.object)?.[hit.face?.materialIndex ?? 0];
    if (!state || !hit.uv) return '#' + (hit.object.material?.color?.getHexString() ?? 'ffffff');
    const coordinate = hit.uv.clone();
    state.texture.transformUv(coordinate);
    const offset = (Math.min(1023, Math.floor(coordinate.y * 1024)) * 1024 + Math.min(1023, Math.floor(coordinate.x * 1024))) * 4;
    return '#' + [...state.pixels.data.slice(offset, offset + 3)].map(channel => channel.toString(16).padStart(2, '0')).join('');
  }

  serialize() {
    return { version: 1, maps: this.states.map(state => ({ id: state.id, png: state.canvas.toDataURL('image/png').split(',')[1] })) };
  }

  async restore(data) {
    if (!data || data.version !== 1 || !Array.isArray(data.maps)) return;
    for (const map of data.maps) {
      const state = this.states.find(state => state.id === map.id);
      if (!state || typeof map.png !== 'string' || map.png.length > 12 * 1024 * 1024 || !/^[a-zA-Z0-9+/=]+$/.test(map.png)) continue;
      const image = await imageFromData('data:image/png;base64,' + map.png);
      state.context.drawImage(image, 0, 0, 1024, 1024);
      state.pixels.data.set(state.context.getImageData(0, 0, 1024, 1024).data);
      state.texture.needsUpdate = true;
    }
    this.undoStack = [];
    this.redoStack = [];
  }

  history() { return { undo: this.undoStack.length, redo: this.redoStack.length }; }

  checksum() {
    let hash = 2166136261;
    for (const state of this.states) for (const pixel of state.pixels.data) hash = Math.imul(hash ^ pixel, 16777619);
    return hash >>> 0;
  }
}
