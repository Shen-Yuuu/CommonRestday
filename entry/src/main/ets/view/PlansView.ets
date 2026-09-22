import { promptAction } from '@kit.ArkUI';
import { CommonTimeQueryService, LOCAL_ONLY_NOTE, PlanConflictView, PlanOpResult, PlanSummary,
  PlanUseCase, calendarBadgeOf, canRetryCalendarSync, isOnSystemCalendar } from 'feature';
import { DateLabel } from 'commons';
import { planKindLabel } from '../util/PlanKindUtil';
import { AccessibilityPolicy } from '../accessibility/AccessibilityPolicy';
import { DesignTokens } from '../theme/DesignTokens';

/**
 * 计划列表（US5 / FR-010 / FR-012，阶段 2 Task 2.3）：
 * 共同时间页「共同计划」分段的内容，页头由宿主分段承担，条目一律走 feature 读模型。
 * - 冲突条目：原因（已按对方隐私等级降维）+ 受影响区间 + 替代窗口，给四个动作——
 *   采用替代时间 / 重新选择窗口 / 保留原计划 / 取消计划；
 * - "保留原计划"只是不再催改期，冲突事实与状态都留着，安排再变动会重新提示；
 * - 日历没写成的条目常驻"仅保存在应用内"，并提供补写入口（改期失败后同一条路径可重试）；
 * - 监听 recomputeCount 刷新（创建/取消/课表变更自动重算后状态同步）。
 */
@Component
export struct PlansView {
  /** 宿主切换到"时间窗口"分段：分段归宿主，这里只提请求。 */
  onGoWindow: () => void = () => {
  };
  @State plans: PlanSummary[] = [];
  @State loading: boolean = true;
  /** 同一时刻只放行一个写操作：改期/取消/补写日历都会重排列表，并发点击只会互相踩。 */
  @State private working: boolean = false;
  // 装饰器实参必须是字面量，取值与 SENIOR_MODE_KEY 保持一致。
  @StorageProp('crd_senior_mode') senior: boolean = false;
  @StorageProp('recomputeCount') @Watch('onRecomputeChanged') recomputeCount: number = 0;

  aboutToAppear(): void {
    this.reload();
  }

  /** 重算广播（创建/取消计划、课表/参数变更）→ 重新读列表（状态与冲突解释同步）。 */
  onRecomputeChanged(): void {
    this.reload();
  }

  reload(): void {
    CommonTimeQueryService.getPlanCards().then((rows: PlanSummary[]) => {
      this.plans = rows;
      this.loading = false;
    }).catch(() => {
      this.plans = [];
      this.loading = false;
    });
  }

  statusLabel(s: string): string {
    if (s === 'CONFLICT') {
      return '冲突';
    }
    if (s === 'CANCELLED') {
      return '已取消';
    }
    return '已确认';
  }

  statusColor(s: string): ResourceColor {
    if (s === 'CONFLICT') {
      return $r('app.color.danger_red');
    }
    if (s === 'CANCELLED') {
      return $r('app.color.text_hint');
    }
    return $r('app.color.success_green');
  }

  /** 列表键：状态/冲突解释/日历状态任一变化都要重绘卡片（改文案不改键，键只吃解释文本）。 */
  cardKey(p: PlanSummary): string {
    const kept = p.conflict != null && p.conflict.kept ? '1' : '0';
    return p.id + '-' + p.status + '-' + p.conflictText + '-' + kept + '-' + p.calendarState;
  }

  subLabel(p: PlanSummary): string {
    return planKindLabel(p.kind) + ' · ' + DateLabel.mdw(Math.floor(p.start / 1440)) + ' '
      + DateLabel.endLabel(p.start, p.end) + ' · ' + DateLabel.duration(p.end - p.start);
  }

  private say(msg: string): void {
    promptAction.showToast({ message: msg });
  }

  /** 点击计划 → 操作弹窗（冲突条目额外给"改到替代时间"）。 */
  onPlanTap(p: PlanSummary): void {
    const alt = p.conflict != null && p.conflict.altStart > 0;
    this.getUIContext().showAlertDialog({
      title: p.title,
      message: this.subLabel(p),
      primaryButton: {
        value: alt ? '改到替代时间' : '取消计划',
        action: () => {
          if (alt) {
            this.askAcceptAlternative(p);
          } else {
            this.confirmCancel(p);
          }
        }
      },
      secondaryButton: {
        value: '关闭',
        action: () => {
        }
      }
    });
  }

  /** 取消计划二次确认。 */
  confirmCancel(p: PlanSummary): void {
    this.getUIContext().showAlertDialog({
      title: '取消计划',
      message: '确定取消「' + p.title + '」？该时段将恢复空闲，系统日历日程（如有）会一并移除。',
      primaryButton: {
        value: '确定取消',
        action: () => this.doCancel(p)
      },
      secondaryButton: {
        value: '暂不',
        action: () => {
        }
      }
    });
  }

  async doCancel(p: PlanSummary): Promise<void> {
    if (this.working) {
      return;
    }
    this.working = true;
    const r: PlanOpResult = await PlanUseCase.cancelPlan(p.id);
    this.say(r.ok ? '已取消计划，该时段恢复空闲' : r.error);
    this.reload();
    this.working = false;
  }

  /** 采用替代时间（冲突动作一）：二次确认后级联改期（日历日程与提醒同步迁移）。 */
  askAcceptAlternative(p: PlanSummary): void {
    const c = p.conflict;
    const when = c != null && c.altStart > 0
      ? DateLabel.mdw(Math.floor(c.altStart / 1440)) + ' ' + DateLabel.endLabel(c.altStart, c.altEnd)
      : '';
    this.getUIContext().showAlertDialog({
      title: '改到替代时间',
      message: (when !== '' ? '新时间：' + when + '。' : '') + '系统日历日程与提醒会一并更新。',
      primaryButton: {
        value: '确认改期',
        action: () => this.doAcceptAlternative(p)
      },
      secondaryButton: {
        value: '暂不',
        action: () => {
        }
      }
    });
  }

  async doAcceptAlternative(p: PlanSummary): Promise<void> {
    if (this.working) {
      return;
    }
    this.working = true;
    const r: PlanOpResult = await PlanUseCase.acceptAlternative(p.id);
    if (!r.ok) {
      this.say(r.error);
    } else {
      // 计划已经改到新时间；日历没跟上时不喊失败，条目上的补写入口就是重试
      this.say(isOnSystemCalendar(r.calendarState) ? '已改期，日历与提醒已同步'
        : '已改期（' + LOCAL_ONLY_NOTE + '）');
    }
    this.reload();
    this.working = false;
  }

  /** 保留原计划（冲突动作三）：不再催改期，冲突状态原样留着。 */
  async doKeepOriginal(p: PlanSummary): Promise<void> {
    if (this.working) {
      return;
    }
    this.working = true;
    const kept = await PlanUseCase.keepOriginalPlan(p.id);
    this.say(kept ? '已按原时间保留，不再提示改期' : '这条计划已经没有待处理的冲突');
    this.reload();
    this.working = false;
  }

  /** 把"仅保存在应用内"的计划补写到系统日历（改期/创建失败后的重试入口）。 */
  async doSyncCalendar(p: PlanSummary): Promise<void> {
    if (this.working) {
      return;
    }
    this.working = true;
    const r: PlanOpResult = await PlanUseCase.syncToCalendar(p.id);
    this.say(r.ok ? '已写入系统日历' : r.error);
    this.reload();
    this.working = false;
  }

  build() {
    List({ space: 12 }) {
      if (this.loading) {
        ListItem() {
          Text('加载中…').fontSize(14).fontColor($r('app.color.text_tertiary')).margin({ top: 40 })
        }
      } else if (this.plans.length === 0) {
        // 空态引导（US5：窗口 → 计划的转化出口）
        ListItem() {
          Column({ space: 12 }) {
            SymbolGlyph($r('sys.symbol.heart'))
              .fontSize(44)
              .fontColor([$r('app.color.brand_pink_muted')])
              .accessibilityLevel('no')
            Text('还没有计划').fontSize(16).fontWeight(FontWeight.Medium)
            Text($r('app.string.plans_empty_desc'))
              .fontSize(12).fontColor($r('app.color.text_tertiary')).textAlign(TextAlign.Center)
            Button('去选一个窗口创建计划')
              .backgroundColor($r('app.color.brand_pink'))
              .borderRadius(22)
              .constraintSize({ minHeight: AccessibilityPolicy.minHit(this.senior) })
              .onClick(() => {
                this.onGoWindow();
              })
          }
          .alignItems(HorizontalAlign.Center)
          .width('100%').padding({ top: 36, bottom: 36, left: 24, right: 24 }).borderRadius(20)
          .backgroundColor($r('app.color.brand_pink_bg'))
        }
      } else {
        // Repeat（API 26 稳定）替代 ForEach：键值 diff 更高效，行为一致
        Repeat<PlanSummary>(this.plans)
          .key((p: PlanSummary) => this.cardKey(p))
          .each((ri: RepeatItem<PlanSummary>) => {
            ListItem() {
              this.planCard(ri.item)
            }
            .swipeAction({
              end: () => {
                this.cancelSwipe(ri.item)
              },
              edgeEffect: SwipeEdgeEffect.Spring
            })
          })
      }
    }
    .padding(0)
    .width('100%').height('100%')
  }

  /** 左滑露出的"取消计划"按钮（点击走原有二次确认弹窗）。 */
  @Builder
  cancelSwipe(p: PlanSummary) {
    Row() {
      Text('取消计划').fontSize(14).fontColor('#FFFFFF')
    }
    .width(88)
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor($r('app.color.danger_red'))
    .borderRadius(14)
    .focusable(true)
    .accessibilityText('取消计划：' + p.title)
    .onClick(() => this.confirmCancel(p))
  }

  /** 计划卡片：状态竖条 + 标题/类型/时间 + 冲突解释与四个动作 + 日历徽标。 */
  @Builder
  planCard(p: PlanSummary) {
    Row({ space: 12 }) {
      Column().width(4).height(40).borderRadius(2)
        .backgroundColor(p.status === 'CONFLICT'
          ? $r('app.color.danger_red')
          : (p.status === 'CANCELLED' ? $r('app.color.text_hint') : $r('app.color.brand_pink')))
        // 状态另有文字标注（冲突/已取消/已确认），色条只是重复信息
        .accessibilityLevel('no')
      Column({ space: 6 }) {
        Row() {
          Text(p.title).fontSize(15).fontWeight(FontWeight.Medium).layoutWeight(1)
          Row({ space: 4 }) {
            if (p.status === 'CONFLICT') {
              Circle().width(8).height(8).fill($r('app.color.danger_red'))
                .accessibilityLevel('no')
            }
            Text(this.statusLabel(p.status)).fontSize(12)
              .fontColor(this.statusColor(p.status))
          }
        }
        .width('100%')
        // 标题和状态各念一遍会打断，合成一句更省事
        .accessibilityGroup(true)
        .accessibilityText(p.title + '，' + this.statusLabel(p.status))

        Text(this.subLabel(p))
          .fontSize(12).fontColor($r('app.color.text_tertiary'))

        if (p.conflict != null) {
          this.conflictBlock(p, p.conflict)
        } else {
          // 整卡可点，但读屏用户滑不动也"点整张卡"没有朗读名：
          // 这条提示就是取消动作的无障碍出口，被打包时也不影响朗读（卡片文案里带着同一句话）
          Text('点击可取消计划').fontSize(11).fontColor($r('app.color.text_hint'))
            .constraintSize({ minHeight: AccessibilityPolicy.minHit(this.senior) })
            .focusable(true)
            .accessibilityText('查看这条计划的取消选项：' + p.title)
            .onClick(() => this.onPlanTap(p))
        }

        if (calendarBadgeOf(p.calendarState) !== '') {
          this.calendarBlock(p, calendarBadgeOf(p.calendarState))
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .width('100%').padding(16).borderRadius(20).backgroundColor($r('app.color.card_bg'))
    .shadow({ radius: 16, color: $r('app.color.shadow_soft'), offsetX: 0, offsetY: 4 })
    .onClick(() => this.onPlanTap(p))
  }

  /** 冲突解释 + 四个动作（Task 2.3）。 */
  @Builder
  conflictBlock(p: PlanSummary, c: PlanConflictView) {
    Column({ space: 6 }) {
      Text(c.reasonText).fontSize(12).fontWeight(FontWeight.Medium).fontColor($r('app.color.danger_red'))
      if (c.affectedText !== '') {
        Text(c.affectedText).fontSize(11).fontColor($r('app.color.text_tertiary'))
      }
      if (c.kept) {
        Text('已按原时间保留，你们的安排再变动时会重新提示')
          .fontSize(11).fontColor($r('app.color.text_hint'))
      } else if (c.altText !== '') {
        Text(c.altText).fontSize(12).fontColor($r('app.color.brand_pink'))
        Button('改到替代时间').fontSize(12)
          .constraintSize({ minHeight: AccessibilityPolicy.minHit(this.senior) })
          .backgroundColor($r('app.color.brand_pink'))
          .onClick(() => this.askAcceptAlternative(p))
      } else {
        Text('未来暂无合适的替代窗口，可以保留原计划或另找时间')
          .fontSize(11).fontColor($r('app.color.text_hint'))
      }
      Flex({ wrap: FlexWrap.Wrap }) {
        this.linkAction('重新选窗口', p.title, $r('app.color.info_blue'), () => {
          this.onGoWindow();
        })
        if (c.kept && c.altStart > 0) {
          this.linkAction('仍然改期', p.title, $r('app.color.info_blue'), () => this.askAcceptAlternative(p))
        } else if (!c.kept) {
          this.linkAction('保留原计划', p.title, $r('app.color.info_blue'), () => this.doKeepOriginal(p))
        }
        this.linkAction('取消计划', p.title, $r('app.color.danger_red'), () => this.confirmCancel(p))
      }
      .width('100%')
    }
    .width('100%')
    .padding({ top: 6, bottom: 6, left: 10, right: 10 })
    .borderRadius(8)
    .backgroundColor($r('app.color.danger_bg'))
    .alignItems(HorizontalAlign.Start)
  }

  /** 日历徽标：计划只存在应用内时常驻说明，能力可用时给出补写入口。 */
  @Builder
  calendarBlock(p: PlanSummary, badge: string) {
    Row({ space: 8 }) {
      Text(badge).fontSize(11).fontColor($r('app.color.text_secondary')).layoutWeight(1)
      if (canRetryCalendarSync(p.calendarState)) {
        this.linkAction('写入日历', p.title, $r('app.color.info_blue'), () => this.doSyncCalendar(p))
      }
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
  }

  /**
   * 卡内文字链：朗读名带上计划标题（只剩一句"取消计划"时，列表里第几条无从判断），
   * 热区按 44/48vp 走，2 倍字号下靠外层 Flex 换行而不是挤出卡片。
   */
  @Builder
  linkAction(label: string, plan: string, tone: ResourceColor, onTap: () => void) {
    Text(label)
      .fontSize(12).fontColor(tone)
      .padding({ right: DesignTokens.space4, top: DesignTokens.space1, bottom: DesignTokens.space1 })
      .constraintSize({ minHeight: AccessibilityPolicy.minHit(this.senior) })
      .focusable(true)
      .accessibilityText(label + '：' + plan)
      .onClick(onTap)
  }
}
