import { OWNER_ME, OWNER_PARTNER } from 'domain';

/** 携带 owner 的路由参数（四条录入链路"我/伴侣"双侧复用）。 */
export interface OwnerRouteParam {
  owner: string;
}

/** 从路由参数解析 owner；缺省/非法回退 'ME'（单人参见既有行为）。 */
export function ownerFromParams(raw: Object | undefined): string {
  if (raw === undefined || raw === null) {
    return OWNER_ME;
  }
  const p = raw as OwnerRouteParam;
  return p.owner === OWNER_PARTNER ? OWNER_PARTNER : OWNER_ME;
}
