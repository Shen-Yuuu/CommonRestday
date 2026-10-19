import { CompanionScenePose } from './CompanionNarrative';
/** Canonical 120x120 image fit, shared by native layers and the browser review. */
export interface CompanionRigPart { slot: number; clip: string; pivotX: number; pivotY: number; }
export const BUBU_EAR: CompanionRigPart = {
  slot: 0, clip: 'M84 28H120V65H96L84 45Z', pivotX: 96, pivotY: 59
};
export const BUBU_PAW: CompanionRigPart = {
  slot: 1, clip: 'M22.5 105C21 94 27 87 37 87C46 86 53 94 53 101L51 106H23Z', pivotX: 37, pivotY: 104
};
export const XIUXIU_EAR_LEFT: CompanionRigPart = {
  slot: 2, clip: 'M0 28H64V65L39 80H0Z', pivotX: 51, pivotY: 62
};
export const XIUXIU_EAR_RIGHT: CompanionRigPart = {
  slot: 3, clip: 'M59 0H102V55H83L68 56H59Z', pivotX: 77, pivotY: 55.5
};
export const XIUXIU_PAW: CompanionRigPart = {
  slot: 4, clip: 'M83 112C81 106 85 99 92 99C99 98 105 103 106 109L105 114H83Z', pivotX: 94, pivotY: 111
};
export const BUBU_PAW_FAR: CompanionRigPart = {
  slot: 5, clip: 'M63.6 104.5C62.5 95 65 89 73 89C81 88 89 94 91 101.8L91 106H63.6Z', pivotX: 78, pivotY: 104
};
export const XIUXIU_PAW_FAR: CompanionRigPart = {
  slot: 6, clip: 'M48 112C46 106 49 100 57 99C64 97 73 102 74 108L73 114H48Z', pivotX: 61, pivotY: 111
};
export const BUBU_RIG_X: number = 40;
export const BUBU_RIG_Y: number = -6.9;
export const BUBU_RIG_SCALE: number = .48;
export const XIUXIU_RIG_X: number = 12;
export const XIUXIU_RIG_Y: number = .7;
export const XIUXIU_RIG_SCALE: number = .38;
/** Upright story-4 contact interval only, measured from calibrated visible paw edges, in vp. */
export function companionNearPawGap(pose: CompanionScenePose): number {
  return BUBU_RIG_X + pose.bubu.x + (23 + pose.bubu.pawX) * BUBU_RIG_SCALE
    - (XIUXIU_RIG_X + pose.xiuxiu.x + (105 + pose.xiuxiu.pawX) * XIUXIU_RIG_SCALE);
}
