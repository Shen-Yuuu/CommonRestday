/** Pure decorative transforms; never encode pairing, read receipts or plan state. */
export interface CompanionSquishSpec {
  depth: number;
  peak: number;
  pressMs: number;
  duration: number;
  wobble: boolean;
}

export interface CompanionTransform {
  x: number;
  y: number;
  angle: number;
}

function bounded(value: number, low: number, high: number): number {
  return Math.max(low, Math.min(high, value));
}

function smooth(progress: number): number {
  const t = bounded(progress, 0, 1);
  return (1 - Math.cos(Math.PI * t)) / 2;
}

export function companionSlotWidth(availableWidth: number): number {
  return availableWidth > 0 && availableWidth < 340 ? 100 : 112;
}

export function nextCompanionCombo(previous: number, lastTap: number, now: number): number {
  const gap = now - lastTap;
  return previous > 0 && gap >= 0 && gap <= 500 ? Math.min(5, previous + 1) : 1;
}

export function companionSquishSpec(combo: number, reduced: boolean,
  depthRandom: number, peakRandom: number, timeRandom: number): CompanionSquishSpec {
  const index = bounded(Math.floor(combo), 1, 5) - 1;
  const depths: number[] = [0.68, 0.63, 0.57, 0.52, 0.48];
  const peaks: number[] = [1.18, 1.22, 1.27, 1.33, 1.38];
  const durations: number[] = [580, 620, 660, 700, 780];
  return {
    depth: bounded(depths[index] + (bounded(depthRandom, 0, 1) - 0.5) * 0.06, reduced ? 0.84 : 0.48, 0.84),
    peak: bounded(peaks[index] + (bounded(peakRandom, 0, 1) - 0.5) * 0.08, 1.08, reduced ? 1.08 : 1.38),
    pressMs: Math.round(90 + (bounded(timeRandom, 0, 1) - 0.5) * 30),
    duration: durations[index],
    wobble: index === 4 && !reduced
  };
}

/** Shared-image phase: a gentle 2.8s whole-duo breath, not independent character breathing. */
export function companionBreath(progress: number): number {
  return progress <= 0 || progress >= 1 ? 1 : 1 + 0.015 * Math.sin(progress * Math.PI * 2);
}

/** Four explicit milestones; fresh presses interpolate from the current displayed transform. */
export function companionSquishFrame(spec: CompanionSquishSpec, elapsed: number,
  fromX: number, fromY: number, fromAngle: number): CompanionTransform {
  if (elapsed >= spec.duration) { return { x: 1, y: 1, angle: 0 }; }
  const time = Math.max(0, elapsed);
  const pressedX = 1 + (1 - spec.depth) * 1.1875;
  const peakX = 1 - (spec.peak - 1) * 2 / 3;
  let x: number;
  let y: number;
  let angle: number = 0;
  if (time <= spec.pressMs) {
    const t = smooth(time / spec.pressMs);
    x = fromX + (pressedX - fromX) * t;
    y = fromY + (spec.depth - fromY) * t;
    angle = fromAngle * (1 - t);
  } else if (time <= spec.pressMs + 190) {
    const t = smooth((time - spec.pressMs) / 190);
    x = pressedX + (peakX - pressedX) * t;
    y = spec.depth + (spec.peak - spec.depth) * t;
  } else if (time <= spec.pressMs + 350) {
    const t = smooth((time - spec.pressMs - 190) / 160);
    x = peakX + (1.03 - peakX) * t;
    y = spec.peak + (0.96 - spec.peak) * t;
  } else {
    const t = smooth((time - spec.pressMs - 350) / (spec.duration - spec.pressMs - 350));
    x = 1.03 + (1 - 1.03) * t;
    y = 0.96 + (1 - 0.96) * t;
  }
  if (spec.wobble && time > spec.pressMs + 190) {
    const t = bounded((time - spec.pressMs - 190) / (spec.duration - spec.pressMs - 190), 0, 1);
    angle = 5 * Math.sin(t * Math.PI * 2) * (1 - t);
  }
  return { x: x, y: y, angle: angle };
}
