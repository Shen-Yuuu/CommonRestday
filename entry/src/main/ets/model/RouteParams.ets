import { OWNER_ME, OWNER_PARTNER } from 'domain';

/** 携带 owner 的路由参数（四条录入链路"我/伴侣"双侧复用）。 */
export interface OwnerRouteParam {
  owner: string;
}

/** 图片课表入口只接受两个已知来源；owner 仍沿用统一校验。 */
export interface CourseImageRouteParam {
  owner: string;
  source: string;
}

export function courseImageParam(owner: string, source: string): CourseImageRouteParam {
  return { owner: owner, source: source === 'camera' ? 'camera' : 'album' };
}

export function courseImageSource(raw: Object | undefined): string {
  if (raw === undefined || raw === null) { return ''; }
  const params = raw as CourseImageRouteParam;
  return params.source === 'camera' || params.source === 'album' ? params.source : '';
}

/**
 * 组装 owner 路由参数：pushUrl 的 router 页与 NavPathStack 的栈目的地共用同一个形状，
 * 少一处手写对象就少一处漏传 owner 的可能（漏传会被回退成"我"，代录侧数据写错人）。
 */
export function ownerParam(owner: string): OwnerRouteParam {
  const p: OwnerRouteParam = { owner: owner };
  return p;
}

/** 从路由参数解析 owner；缺省/非法回退 'ME'（单人参见既有行为）。 */
export function ownerFromParams(raw: Object | undefined): string {
  if (raw === undefined || raw === null) {
    return OWNER_ME;
  }
  const p = raw as OwnerRouteParam;
  return p.owner === OWNER_PARTNER ? OWNER_PARTNER : OWNER_ME;
}
