/** Actor-local ear/paw coordinates use the 120x120 rig; x/y translations are viewport vp. */
export interface CompanionActorPose {
  x: number; y: number; angle: number; face: number;
  earLeft: number; earRight: number; pawX: number; pawY: number; pawOpacity: number;
  scaleX: number; scaleY: number;
}
export interface CompanionScenePose { bubu: CompanionActorPose; xiuxiu: CompanionActorPose; }
interface StoryKey { at: number; pose: CompanionScenePose; }
function actor(paw: number): CompanionActorPose {
  return { x: 0, y: 0, angle: 0, face: 0, earLeft: 0, earRight: 0,
    pawX: 0, pawY: 0, pawOpacity: paw, scaleX: 1, scaleY: 1 };
}
export function companionIdlePose(): CompanionScenePose {
  const bubu = actor(0), xiuxiu = actor(0);
  bubu.pawX = 28; xiuxiu.pawX = -8;
  return { bubu: bubu, xiuxiu: xiuxiu };
}
function sameActor(a: CompanionActorPose, b: CompanionActorPose): boolean {
  return a.x === b.x && a.y === b.y && a.angle === b.angle && a.face === b.face
    && a.earLeft === b.earLeft && a.earRight === b.earRight && a.pawX === b.pawX && a.pawY === b.pawY
    && a.pawOpacity === b.pawOpacity && a.scaleX === b.scaleX && a.scaleY === b.scaleY;
}
export function companionSameScene(a: CompanionScenePose, b: CompanionScenePose): boolean {
  return sameActor(a.bubu, b.bubu) && sameActor(a.xiuxiu, b.xiuxiu);
}
export function companionNarrativeDuration(kind: number): number {
  return kind === 0 ? 12000 : kind === 1 || kind === 3 ? 10000 : kind === 2 ? 8000 : 0;
}
function key(at: number): StoryKey { return { at: at, pose: companionIdlePose() }; }
function keys(kind: number): StoryKey[] {
  const a = key(0);
  if (kind === 0) {
    const b = key(4000), c = key(5200), d = key(7000), e = key(8200), f = key(8600), g = key(12000);
    c.pose.xiuxiu.angle = 9; c.pose.xiuxiu.face = 1; c.pose.bubu.face = 1;
    d.pose.xiuxiu.angle = 9; d.pose.xiuxiu.face = 1; d.pose.bubu.face = 1;
    e.pose.bubu.earRight = 6;
    return [a, b, c, d, e, f, g];
  }
  if (kind === 1) {
    const b = key(2500), c = key(3500), d = key(7000), e = key(7400), f = key(8200), g = key(10000);
    b.pose.xiuxiu.angle = -8; b.pose.xiuxiu.face = 3;
    for (const hold of [c, d]) {
      hold.pose.xiuxiu.x = 4; hold.pose.xiuxiu.angle = 4; hold.pose.xiuxiu.face = 3;
      hold.pose.bubu.face = 3; hold.pose.bubu.earRight = 8;
    }
    e.pose.xiuxiu.angle = -2; e.pose.xiuxiu.face = 1; e.pose.bubu.face = 1;
    return [a, b, c, d, e, f, g];
  }
  if (kind === 2) {
    const b = key(1500), c = key(1650), d = key(2200), e = key(4000), f = key(6000), g = key(6800), h = key(8000);
    b.pose.xiuxiu.earRight = 18; c.pose.xiuxiu.earRight = 18;
    c.pose.bubu.scaleX = .97; c.pose.bubu.scaleY = 1.03;
    for (const hold of [d, e]) {
      hold.pose.xiuxiu.earRight = 18; hold.pose.xiuxiu.face = 2;
      hold.pose.bubu.face = 1;
    }
    d.pose.bubu.earRight = -10; f.pose.xiuxiu.earRight = 18;
    return [a, b, c, d, e, f, g, h];
  }
  if (kind === 3) {
    const b = key(2500), c = key(3500), d = key(5500), e = key(7500), f = key(10000);
    b.pose.bubu.pawX = 10; b.pose.bubu.pawOpacity = 1;
    for (const hold of [c, d]) {
      hold.pose.bubu.pawX = 10; hold.pose.bubu.pawOpacity = 1;
      hold.pose.xiuxiu.pawX = 0; hold.pose.xiuxiu.pawOpacity = 1;
    }
    return [a, b, c, d, e, f];
  }
  return [a];
}
function mix(a: number, b: number, ratio: number): number { return a + (b - a) * ratio; }
const TIMELINES: StoryKey[][] = [keys(0), keys(1), keys(2), keys(3)];
function blend(a: CompanionActorPose, b: CompanionActorPose, ratio: number, reached: boolean): CompanionActorPose {
  return { x: mix(a.x, b.x, ratio), y: mix(a.y, b.y, ratio), angle: mix(a.angle, b.angle, ratio),
    face: reached ? b.face : a.face, earLeft: mix(a.earLeft, b.earLeft, ratio), earRight: mix(a.earRight, b.earRight, ratio),
    pawX: mix(a.pawX, b.pawX, ratio), pawY: mix(a.pawY, b.pawY, ratio), pawOpacity: mix(a.pawOpacity, b.pawOpacity, ratio),
    scaleX: mix(a.scaleX, b.scaleX, ratio), scaleY: mix(a.scaleY, b.scaleY, ratio) };
}
export function companionBlendScene(a: CompanionScenePose, b: CompanionScenePose, progress: number): CompanionScenePose {
  const ratio = Number.isFinite(progress) ? Math.min(1, Math.max(0, progress)) : 1;
  return { bubu: blend(a.bubu, b.bubu, ratio, ratio >= .5), xiuxiu: blend(a.xiuxiu, b.xiuxiu, ratio, ratio >= .5) };
}
export function companionIdleFrame(elapsed: number, bunnyBlinkAt: number, bearBlinkAt: number, earAt: number): CompanionScenePose {
  const pose = companionIdlePose();
  if (!Number.isFinite(elapsed)) return pose;
  if (elapsed >= bunnyBlinkAt && elapsed < bunnyBlinkAt + 160) pose.xiuxiu.face = 3;
  if (elapsed >= bearBlinkAt && elapsed < bearBlinkAt + 160) pose.bubu.face = 3;
  const earTime = elapsed - earAt;
  if (earTime >= 0 && earTime < 300) pose.xiuxiu.earLeft = Math.sin(earTime / 300 * Math.PI * 2) * 6;
  const pawTime = elapsed - earAt - 400;
  if (pawTime >= 0 && pawTime < 400) pose.bubu.pawY = Math.sin(pawTime / 400 * Math.PI) * 3;
  return pose;
}
export function companionNarrativeFrame(kind: number, elapsed: number): CompanionScenePose {
  const duration = companionNarrativeDuration(kind);
  if (!Number.isFinite(elapsed) || elapsed <= 0 || duration <= 0 || elapsed >= duration) return companionIdlePose();
  const timeline = TIMELINES[kind];
  for (let i = 1; i < timeline.length; i++) {
    const right = timeline[i], left = timeline[i - 1];
    if (elapsed <= right.at) {
      const progress = Math.min(1, Math.max(0, (elapsed - left.at) / (right.at - left.at)));
      const smooth = progress * progress * (3 - 2 * progress);
      return { bubu: blend(left.pose.bubu, right.pose.bubu, smooth, elapsed === right.at),
        xiuxiu: blend(left.pose.xiuxiu, right.pose.xiuxiu, smooth, elapsed === right.at) };
    }
  }
  return companionIdlePose();
}
