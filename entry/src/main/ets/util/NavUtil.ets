import { NavRoutes, NavParams } from '../navigation/NavRoutes';
import { ownerFromParams } from '../model/RouteParams';

/**
 * 导航请求入口：跨 Tab 广播 + 深链参数解析。
 *
 * 广播：页面/视图内无法直接操作壳层的 Tabs，用 AppStorage 计数广播，
 * AppNavigator 通过 @StorageProp + @Watch 监听并切换。
 * 深链：服务卡片 postCardAction 与 Want 的参数来自进程外，必须过白名单才能用于导航。
 */
export const NAV_TO_ME_KEY = 'navToMeCount';
export const NAV_TO_COTIME_KEY = 'navToCoTimeCount';
/** 共同时间页落地分段请求键：与计数广播配套，消费后清空。 */
export const COTIME_SEGMENT_KEY = 'navToCoTimeSegment';
/** 共同时间页的两个一级分段（取值与 CoTimeView 的分段常量一致）。 */
export const COTIME_SEG_WINDOW = 'window';
export const COTIME_SEG_PLANS = 'plans';
/** 待消费的深链路由名（卡片/Want 拉起）：EntryAbility 写入，壳层取走后清空。 */
export const PENDING_ROUTE_KEY = 'crdPendingRoute';
/** 变更广播键：同一条路由连续拉起两次也要跳第二回，所以触发靠计数而不是名字。 */
export const PENDING_ROUTE_COUNT_KEY = 'crdPendingRouteCount';
/** 卡片 postCardAction 的 params 在 Want 侧的封装键（部分版本把整个 params 打成 JSON 串放在这里）。 */
const WANT_PACKED_PARAMS = 'key_params';

/**
 * 深链参数的宽松视图：只用可选字段，缺键即"没有该意图"。
 * `route` 是卡片 postCardAction 与 Want 深链的约定键，取值必须是 NavRoutes 白名单里的名字。
 */
interface DeepLinkParams {
  route?: string;
}

/** 请求切换到「我的」Tab（添加伴侣引导等入口使用）。 */
export function navToMe(): void {
  const cur: number = AppStorage.get<number>(NAV_TO_ME_KEY) ?? 0;
  AppStorage.setOrCreate<number>(NAV_TO_ME_KEY, cur + 1);
}

/**
 * 请求切换到「共同」Tab（计划页空态引导、首页冲突条使用）。
 * segment 非空时一并请求落地分段：分段先写、计数后加，监听方读到的一定是本次请求。
 */
export function navToCoTime(segment: string = ''): void {
  AppStorage.setOrCreate<string>(COTIME_SEGMENT_KEY, segment);
  const cur: number = AppStorage.get<number>(NAV_TO_COTIME_KEY) ?? 0;
  AppStorage.setOrCreate<number>(NAV_TO_COTIME_KEY, cur + 1);
}

/** 取走并清空分段请求：空串表示"只切 Tab，不动分段"。 */
export function takeCoTimeSegment(): string {
  const seg: string = AppStorage.get<string>(COTIME_SEGMENT_KEY) ?? '';
  if (seg !== '') {
    AppStorage.setOrCreate<string>(COTIME_SEGMENT_KEY, '');
  }
  return seg;
}

/**
 * 从深链参数取路由名：缺失、非字符串或不在白名单一律返回空串。
 * 返回空串 = 无深链意图，调用方留在首页。
 */
export function routeNameFromParams(raw: Object | undefined): string {
  if (raw === undefined || raw === null) {
    return '';
  }
  const p = raw as DeepLinkParams;
  const name = p.route;
  if (name === undefined || !NavRoutes.isKnown(name)) {
    return '';
  }
  return name;
}

/**
 * 深链参数 → 导航参数：owner 沿用录入页既有口径（缺省/非法回退 'ME'），
 * 其余键一律丢弃，避免进程外参数被原样带进页面。
 */
export function navParamsFrom(raw: Object | undefined): NavParams {
  const out: NavParams = { owner: ownerFromParams(raw) };
  return out;
}

/**
 * Want.parameters → 深链路由名：卡片 postCardAction 的 params 落在 Want 侧，
 * 历史上见过两种形态（平铺在 parameters 里、或整包 JSON 串放在 key_params），两种都试一次。
 * 认不出或不在白名单一律返回空串 = 没有跳转意图：进程外传来的名字绝不当路由用。
 */
export function routeFromWantParams(params: Record<string, Object> | undefined): string {
  if (params == null) {
    return '';
  }
  const flat = routeNameFromParams(params);
  if (flat !== '') {
    return flat;
  }
  const packed: Object | undefined = params[WANT_PACKED_PARAMS];
  if (typeof packed === 'string') {
    try {
      return routeNameFromParams(JSON.parse(packed as string));
    } catch (e) {
      return '';
    }
  }
  return '';
}

/** 登记一次待消费深链：先写名字再 bump 计数，壳层按计数变化取走。 */
export function pushPendingRoute(name: string): void {
  if (name === '') {
    return;
  }
  AppStorage.setOrCreate<string>(PENDING_ROUTE_KEY, name);
  const cur: number = AppStorage.get<number>(PENDING_ROUTE_COUNT_KEY) ?? 0;
  AppStorage.setOrCreate<number>(PENDING_ROUTE_COUNT_KEY, cur + 1);
}

/** 取走并清空待消费深链（空串 = 没有跳转意图）。 */
export function takePendingRoute(): string {
  const name: string = AppStorage.get<string>(PENDING_ROUTE_KEY) ?? '';
  if (name !== '') {
    AppStorage.setOrCreate<string>(PENDING_ROUTE_KEY, '');
  }
  return name;
}
