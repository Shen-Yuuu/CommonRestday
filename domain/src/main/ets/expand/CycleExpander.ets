import { CycleTemplate, MIN_PER_DAY, ScheduleOverride, ShiftInstance } from '../model/Types';

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
  const len = tpl.seq.length;
  for (let i = 0; i < days; i++) {
    const d = startEpochDay + i;
    if (ovMap.has(d)) {
      const v = ovMap.get(d);
      if (v != null) {
        res.push(mkInstance(d, v));
      }
      continue;
    }
    if (len === 0) {
      continue;
    }
    const idx = ((d - tpl.anchorEpochDay) % len + len) % len;
    const typeId = tpl.seq[idx];
    if (typeId != null && typeId !== '') {
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
  if (len === 0) {
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
