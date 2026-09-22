/**
 * 路由名与落地方式的唯一事实。
 *
 * 名字是对外契约：服务卡片的 postCardAction 参数与 Want 深链都按这些字符串传，
 * 改名即破坏已发布卡片的深链，只能新增。
 * 三个底部 Tab 的索引固定 0/1/2，班表不再是 Tab（降级为导航栈目的地）。
 */

/** 路由落地方式。 */
export enum RouteKind {
  /** 底部 Tab：切索引，不入栈。 */
  TAB = 'TAB',
  /** 导航栈目的地：NavPathStack 推入，系统返回键出栈。 */
  STACK = 'STACK',
  /** 仍是 @Entry router 页：迁入导航栈之前保持既有 pushUrl 行为，页面自身不改。 */
  ROUTER = 'ROUTER',
  /** 已占位但页面尚未建立：落到「我的」Tab（配对与隐私设置目前都在那里）。 */
  NOT_READY = 'NOT_READY'
}

/** 路由表条目。 */
export interface RouteTarget {
  name: string;
  kind: RouteKind;
  /** TAB/NOT_READY 的目标 Tab 索引；其余为 NO_TAB。 */
  tab: number;
  /** ROUTER 的既有页面 url；其余为空串。 */
  url: string;
}

/** 导航参数：目前只有录入链路的 owner，其余路由忽略。 */
export interface NavParams {
  owner?: string;
}

export class NavRoutes {
  static readonly HOME: string = 'home';
  static readonly COMMON_TIME: string = 'common-time';
  static readonly ME: string = 'me';
  static readonly SCHEDULE_HUB: string = 'schedule-hub';
  static readonly SHIFT_EDITOR: string = 'shift-editor';
  static readonly CYCLE_EDITOR: string = 'cycle-editor';
  static readonly COURSE_IMPORT: string = 'course-import';
  static readonly PAINT_MONTH: string = 'paint-month';
  static readonly OCR_COURSE: string = 'ocr-course';
  static readonly DATA_PRIVACY: string = 'data-privacy';
  static readonly PAIRING: string = 'pairing';

  static readonly TAB_HOME: number = 0;
  static readonly TAB_COMMON_TIME: number = 1;
  static readonly TAB_ME: number = 2;
  /** 无 Tab 语义时的占位索引（不存在 activeTab=3）。 */
  static readonly NO_TAB: number = -1;

  private static readonly TABLE: RouteTarget[] = [
    { name: NavRoutes.HOME, kind: RouteKind.TAB, tab: NavRoutes.TAB_HOME, url: '' },
    { name: NavRoutes.COMMON_TIME, kind: RouteKind.TAB, tab: NavRoutes.TAB_COMMON_TIME, url: '' },
    { name: NavRoutes.ME, kind: RouteKind.TAB, tab: NavRoutes.TAB_ME, url: '' },
    { name: NavRoutes.SCHEDULE_HUB, kind: RouteKind.STACK, tab: NavRoutes.NO_TAB, url: '' },
    {
      name: NavRoutes.SHIFT_EDITOR, kind: RouteKind.ROUTER,
      tab: NavRoutes.NO_TAB, url: 'pages/ScheduleEditor'
    },
    {
      name: NavRoutes.CYCLE_EDITOR, kind: RouteKind.ROUTER,
      tab: NavRoutes.NO_TAB, url: 'pages/CycleEditor'
    },
    {
      name: NavRoutes.COURSE_IMPORT, kind: RouteKind.ROUTER,
      tab: NavRoutes.NO_TAB, url: 'pages/CourseImport'
    },
    {
      name: NavRoutes.PAINT_MONTH, kind: RouteKind.ROUTER,
      tab: NavRoutes.NO_TAB, url: 'pages/PaintMonth'
    },
    {
      name: NavRoutes.OCR_COURSE, kind: RouteKind.ROUTER,
      tab: NavRoutes.NO_TAB, url: 'pages/OcrCourse'
    },
    { name: NavRoutes.DATA_PRIVACY, kind: RouteKind.NOT_READY, tab: NavRoutes.TAB_ME, url: '' },
    { name: NavRoutes.PAIRING, kind: RouteKind.NOT_READY, tab: NavRoutes.TAB_ME, url: '' }
  ];

  /** 白名单查表：表外的名字返回 null（卡片/Want 参数来自进程外，不可信）。 */
  static resolve(name: string): RouteTarget | null {
    for (let i = 0; i < NavRoutes.TABLE.length; i++) {
      if (NavRoutes.TABLE[i].name === name) {
        return NavRoutes.TABLE[i];
      }
    }
    return null;
  }

  static isKnown(name: string): boolean {
    return NavRoutes.resolve(name) != null;
  }
}
