import { CycleTemplate, ScheduleOverride, ShiftInstance } from '../model/Types';

export const CYCLE_ALL_DAYS: number = 127;

/** 旧模板缺字段与非法存量值回到每天；0 保留为无选中，由保存入口拦住。 */
export function cycleWeekdaysMask(mask?: number): number {
  return mask != null && Number.isInteger(mask) && mask >= 0 && mask <= CYCLE_ALL_DAYS
    ? mask : CYCLE_ALL_DAYS;
}

export function cycleWeekday(epochDay: number): number {
  return ((epochDay + 3) % 7 + 7) % 7 + 1;
}

export function cycleAppliesOn(tpl: CycleTemplate, epochDay: number): boolean {
  return (cycleWeekdaysMask(tpl.weekdaysMask) & (1 << (cycleWeekday(epochDay) - 1))) !== 0;
}

/**
 * 循环展开：模板序列 + 单日覆盖 → 未来若干天的班次实例。
 * 覆盖优先级：override（换班/清空）> 模板。
 * 两条口径要一起成立，涂过班的那几天才不会被画成休：
 * ① 覆盖的"有没有"看**键在不在**——`shiftTypeId=null` 是一条真覆盖，意为"这天强制休息"；
 * ② 模板推不出班（`seq` 为空）只是**循环层**缺位，不提前返回，否则覆盖层跟着一起没了。
 */
export function expandCycle(tpl: CycleTemplate, overrides: ScheduleOverride[],
  startEpochDay: number, days: number): ShiftInstance[] {
  const res: ShiftInstance[] = [];
  const ovMap = new Map<number, string | null>();
  for (let i = 0; i < overrides.length; i++) {
    ovMap.set(overrides[i].epochDay, overrides[i].shiftTypeId);
  }
  for (let i = 0; i < days; i++) {
    const d = startEpochDay + i;
    if (ovMap.has(d)) {
      const v = ovMap.get(d);
      if (v != null) {
        res.push(mkInstance(d, v));
      }
      continue;
    }
    const typeId = cycleShiftAt(tpl, d);
    if (typeId != null) {
      res.push(mkInstance(d, typeId));
    }
  }
  return res;
}

function mkInstance(epochDay: number, typeId: string): ShiftInstance {
  const inst: ShiftInstance = { epochDay: epochDay, typeId: typeId };
  return inst;
}

/** 某日按模板应为何班（不含覆盖）；无模板返回 null。 */
export function cycleShiftAt(tpl: CycleTemplate, epochDay: number): string | null {
  const len = tpl.seq.length;
  if (len === 0 || !cycleAppliesOn(tpl, epochDay)) {
    return null;
  }
  const idx = ((epochDay - tpl.anchorEpochDay) % len + len) % len;
  const v = tpl.seq[idx];
  return v != null && v !== '' ? v : null;
}

/** 天数换算（供 UI 提示等）。 */
export function daysBetween(fromEpochDay: number, toEpochDay: number): number {
  return toEpochDay - fromEpochDay;
}
