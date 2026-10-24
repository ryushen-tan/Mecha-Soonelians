import * as THREE from 'three';

export const posePages = [
  [
    { id: 'original', name: 'Original', icon: 'figure.stand' },
    { id: 'stand', name: 'Stand', icon: 'figure.stand' },
    { id: 'crouch', name: 'Crouch', icon: 'figure.strengthtraining.functional' },
    { id: 'sit', name: 'Sit', icon: 'figure.seated.seatbelt' },
    { id: 'star', name: 'Star', icon: 'figure.arms.open' },
    { id: 'reach', name: 'Reach', icon: 'figure.wave' },
    { id: 'curl', name: 'Curl up', icon: 'figure.flexibility' },
    { id: 'prone', name: 'Lie flat', icon: 'figure.core.training' }
  ],
  [
    { id: 'kneel', name: 'Kneel', icon: 'figure.cooldown' },
    { id: 'side', name: 'Side lie', icon: 'figure.pilates' },
    { id: 'lean', name: 'Lean', icon: 'figure.surfing' },
    { id: 'backbend', name: 'Backbend', icon: 'figure.gymnastics' },
    { id: 'handsUp', name: 'Hands up', icon: 'figure.arms.open' },
    { id: 'balance', name: 'One leg', icon: 'figure.yoga' },
    { id: 'tuck', name: 'Tuck', icon: 'figure.wrestling' },
    { id: 'tpose', name: 'T-pose', icon: 'figure.stand.line.dotted.figure.stand' }
  ]
];

export const boneName = value => value.replace(/^.*[:|]/, '').replace(/^mixamorig\d*[_:]?/i, '').toLowerCase();
const point = bone => bone.getWorldPosition(new THREE.Vector3());

export class HumanoidRig {
  constructor(character) {
    this.character = character;
    const unique = new Set();
    character.traverse(node => { if (node.isSkinnedMesh) node.skeleton.bones.forEach(bone => unique.add(bone)); });
    this.bones = [...unique];
    this.named = new Map(this.bones.map(bone => [boneName(bone.name), bone]));
    this.rest = this.bones.map(bone => bone.quaternion.clone());
    this.target = this.rest.map(quaternion => quaternion.clone());
    this.start = this.target.map(quaternion => quaternion.clone());
    this.preset = 'original';
    this.changedAt = 0;
    this.duration = 280;
    this.axes = [];
    this.limits = [];
    this.canRetarget = ['hips', 'spine', 'leftupleg', 'rightupleg', 'leftarm', 'rightarm'].every(name => this.named.has(name));
    character.updateMatrixWorld(true);
    const leftHip = this.named.get('leftupleg'), rightHip = this.named.get('rightupleg');
    this.right = leftHip && rightHip ? point(rightHip).sub(point(leftHip)) : new THREE.Vector3(1, 0, 0);
    this.right.applyQuaternion(character.getWorldQuaternion(new THREE.Quaternion()).invert()).setY(0).normalize();
    if (this.right.lengthSq() < 0.01) this.right.set(1, 0, 0);
    this.forward = new THREE.Vector3().crossVectors(new THREE.Vector3(0, 1, 0), this.right).normalize();
    this.headOrientation = this.named.get('head')?.getWorldQuaternion(new THREE.Quaternion())
      .premultiply(character.getWorldQuaternion(new THREE.Quaternion()).invert());
    this.surfaceEdges = [];
    character.updateMatrixWorld(true);
    character.traverse(mesh => {
      if (!mesh.isSkinnedMesh) return;
      mesh.skeleton.update();
      const indices = mesh.geometry.index;
      const count = indices?.count ?? mesh.geometry.attributes.position.count;
      const step = Math.max(1, Math.ceil(count / 18000)) * 3;
      const first = new THREE.Vector3(), second = new THREE.Vector3();
      for (let offset = 0; offset + 2 < count; offset += step) {
        for (let edge = 0; edge < 3; edge++) {
          const start = indices ? indices.getX(offset + edge) : offset + edge;
          const end = indices ? indices.getX(offset + (edge + 1) % 3) : offset + (edge + 1) % 3;
          const length = mesh.getVertexPosition(start, first).distanceTo(mesh.getVertexPosition(end, second));
          if (length > 0.00001) this.surfaceEdges.push({ mesh, start, end, length });
        }
      }
    });
    this.calibrate();
  }

  calibrate() {
    this.character.updateMatrixWorld(true);
    this.axes = this.bones.map((bone, index) => {
      const name = boneName(bone.name);
      const child = bone.children.find(node => node.isBone);
      const hinge = /forearm$|^(left|right)leg$/.test(name);
      const limits = hinge ? [[-20, 135], [-45, 45], [-15, 15]] : /spine|neck|head/.test(name)
        ? [[-35, 35], [-60, 60], [-30, 30]] : /hand.*[1234]$/.test(name)
          ? [[-15, 80], [-15, 15], [-15, 15]] : [[-100, 100], [-90, 90], [-100, 100]];
      let bend = new THREE.Vector3(1, 0, 0);
      let twist = new THREE.Vector3(0, 1, 0);
      if (hinge && child && bone.parent?.isBone) {
        const upper = point(bone).sub(point(bone.parent)).normalize();
        const lower = point(child).sub(point(bone)).normalize();
        const flex = THREE.MathUtils.radToDeg(upper.angleTo(lower));
        bend = new THREE.Vector3().crossVectors(upper, lower);
        if (bend.lengthSq() < 0.001) bend.set(1, 0, 0);
        bend.normalize().applyQuaternion(bone.getWorldQuaternion(new THREE.Quaternion()).invert());
        twist = child.position.clone().normalize();
        limits[0] = [-Math.min(flex, 150), Math.max(0, 150 - flex)];
      }
      this.limits[index] = limits;
      return [bend, twist, new THREE.Vector3().crossVectors(bend, twist).normalize()];
    });
  }

  descriptors() {
    return this.bones.map((bone, id) => ({ id, name: bone.name || `Joint ${id + 1}`, limits: this.limits[id] }));
  }

  restore() {
    this.bones.forEach((bone, index) => bone.quaternion.copy(this.rest[index]));
    this.character.updateMatrixWorld(true);
  }

  aim(name, childName, direction) {
    const bone = this.named.get(name.toLowerCase());
    const child = this.named.get(childName.toLowerCase());
    if (!bone || !child) return;
    this.character.updateMatrixWorld(true);
    const current = point(child).sub(point(bone)).normalize();
    const target = direction.clone().normalize().applyQuaternion(this.character.getWorldQuaternion(new THREE.Quaternion()));
    const world = bone.getWorldQuaternion(new THREE.Quaternion());
    const rotation = new THREE.Quaternion().setFromUnitVectors(current, target).multiply(world);
    const parent = bone.parent.getWorldQuaternion(new THREE.Quaternion()).invert();
    bone.quaternion.copy(parent.multiply(rotation)).normalize();
  }

  select(id, angles = {}, immediate = false) {
    if (!posePages.flat().some(pose => pose.id === id)) id = 'original';
    const previous = this.bones.map(bone => bone.quaternion.clone());
    this.restore();
    if (id !== 'original' && this.canRetarget) this.buildPose(id);
    this.preset = id;
    this.calibrate();
    this.base = this.bones.map(bone => bone.quaternion.clone());
    this.target = this.offsets(angles);
    this.start = previous;
    this.changedAt = performance.now();
    if (immediate) this.finish();
    return this.descriptors();
  }

  buildPose(id) {
    const direction = (side, up, front) => this.right.clone().multiplyScalar(side).add(new THREE.Vector3(0, up, 0)).addScaledVector(this.forward, front).normalize();
    const curled = id === 'curl' || id === 'tuck';
    const crouched = id === 'crouch' || curled;
    const sitting = id === 'sit';
    const kneeling = id === 'kneel';
    const lean = id === 'lean' ? 0.3 : id === 'backbend' ? -0.4 : crouched ? 0.2 : 0;
    this.aim('spine', 'spine1', direction(0, 1, lean));
    this.aim('spine1', 'spine2', direction(0, 1, lean));
    this.aim('neck', 'head', direction(0, 1, curled ? 0.5 : 0));
    const head = this.named.get('head');
    if (head && this.headOrientation) {
      const rotation = this.headOrientation.clone();
      if (curled) rotation.premultiply(new THREE.Quaternion().setFromAxisAngle(this.right, -Math.PI / 6));
      head.quaternion.copy(head.parent.getWorldQuaternion(new THREE.Quaternion()).invert()
        .multiply(this.character.getWorldQuaternion(new THREE.Quaternion())).multiply(rotation));
    }
    for (const side of ['left', 'right']) {
      const sign = side === 'left' ? -1 : 1;
      const lifted = id === 'balance' && side === 'right';
      const thigh = sitting ? direction(sign * 0.08, -0.06, 1) : curled ? direction(sign * 0.08, 0.15, 1)
        : crouched ? direction(sign * 0.12, -0.55, 0.85) : kneeling ? direction(sign * 0.06, -0.9, 0.4)
          : lifted ? direction(sign * 0.05, -0.15, 1) : direction(sign * (id === 'star' ? 0.42 : 0.05), -1, 0);
      const shin = curled ? direction(0, -0.25, -1) : crouched ? direction(0, -0.8, -0.6)
        : kneeling ? direction(0, 0, -1) : direction(0, -1, 0);
      this.aim(side + 'upleg', side + 'leg', thigh);
      this.aim(side + 'leg', side + 'foot', shin);
      this.aim(side + 'foot', side + 'toebase', direction(0, -0.1, 1));
      let arm = direction(sign * 0.12, -1, 0.04);
      let forearm = direction(0, -1, 0.12);
      if (['star', 'tpose'].includes(id)) { arm = direction(sign, id === 'star' ? 0.35 : 0, 0); forearm = arm.clone(); }
      if (id === 'handsUp' || (id === 'reach' && side === 'right')) { arm = direction(sign * 0.25, 1, 0); forearm = direction(0, 1, 0.15); }
      if (sitting || crouched || kneeling || curled) { arm = direction(sign * 0.12, -0.8, 0.6); forearm = direction(-sign * (curled ? 0.45 : 0.1), -0.05, 1); }
      if (id === 'prone') { arm = direction(sign * 0.1, 0.5, 0.5); forearm = direction(0, 1, 0); }
      this.aim(side + 'arm', side + 'forearm', arm);
      this.aim(side + 'forearm', side + 'hand', forearm);
    }
  }

  offsets(angles) {
    const base = this.base ?? this.rest;
    return this.bones.map((bone, index) => {
      const result = base[index].clone();
      const values = angles[index] ?? [0, 0, 0];
      values.forEach((value, axis) => {
        const [minimum, maximum] = this.limits[index][axis];
        result.multiply(new THREE.Quaternion().setFromAxisAngle(this.axes[index][axis], THREE.MathUtils.degToRad(THREE.MathUtils.clamp(Number(value) || 0, minimum, maximum))));
      });
      return result.normalize();
    });
  }

  adjust(angles, immediate = false) {
    this.start = this.bones.map(bone => bone.quaternion.clone());
    this.target = this.offsets(angles);
    this.changedAt = performance.now();
    if (immediate) this.finish();
  }

  tick(time = performance.now()) {
    const alpha = THREE.MathUtils.clamp((time - this.changedAt) / this.duration, 0, 1);
    const smooth = alpha * alpha * (3 - 2 * alpha);
    this.bones.forEach((bone, index) => bone.quaternion.slerpQuaternions(this.start[index], this.target[index], smooth));
    return alpha < 1;
  }

  finish() {
    this.changedAt = performance.now() - this.duration;
    this.bones.forEach((bone, index) => bone.quaternion.copy(this.target[index]));
    this.character.updateMatrixWorld(true);
  }

  report() {
    this.character.updateMatrixWorld(true);
    return {
      preset: this.preset, humanoid: this.canRetarget, boneCount: this.bones.length,
      joints: this.bones.map(bone => ({ name: bone.name, parent: bone.parent?.isBone ? bone.parent.name : null, position: point(bone).toArray(), length: bone.position.length() })),
      finite: this.bones.every(bone => [...bone.quaternion.toArray(), ...point(bone).toArray()].every(Number.isFinite))
    };
  }

  surfaceQuality() {
    this.character.updateMatrixWorld(true);
    const first = new THREE.Vector3(), second = new THREE.Vector3();
    const updated = new Set();
    const ratios = this.surfaceEdges.map(edge => {
      if (!updated.has(edge.mesh)) { edge.mesh.skeleton.update(); updated.add(edge.mesh); }
      return edge.mesh.getVertexPosition(edge.start, first).distanceTo(edge.mesh.getVertexPosition(edge.end, second)) / edge.length;
    }).sort((first, second) => first - second);
    const stretch = ratios[Math.floor(ratios.length * 0.95)] ?? 1;
    return { stretch95: stretch, warning: stretch > 2.5
      ? 'This pose stretches the captured mesh. Try a smaller joint adjustment, a rounded body, or a new full-body capture with separated limbs.' : null };
  }
}
