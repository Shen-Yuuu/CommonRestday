import { promptAction } from '@kit.ArkUI';
import { PlanRow, ScheduleRepo } from 'data';
import { DateLabel } from 'commons';
import { PlanUseCase } from 'feature';
import { navToCoTime } from '../util/NavUtil';
import { planKindLabel } from '../util/PlanKindUtil';

/**
 * 计划页（US5 / FR-010 / FR-012）：
 * - listActivePlans 列表：标题/类型/日期起止/状态色（OK 正常 / CONFLICT 红点 + 替代窗口提示）；
 * - 点击计划 → 操作弹窗（取消计划[二次确认 → cancelPlan] / 关闭）；
 * - 监听 recomputeCount 刷新（创建/取消/课表变更自动重算后状态同步）；
 * - 空态引导：去共同时间页选一个窗口创建计划。
 */
@Component
export struct PlansView {
  // 嵌入态标记：被 CoTimeView 分段嵌入时隐藏页头（分段标签已表达"计划"语义）
  embedded: boolean = false;
  // 空态引导回调：嵌入时由宿主切换到"窗口"分段；独立使用时回退 tab 跳转
  onGoWindow: (() => void) | null = null;
  @State plans: PlanRow[] = [];
  @State loading: boolean = true;
  @State cancelling: boolean = false;
  @StorageProp('recomputeCount') @Watch('onRecomputeChanged') recomputeCount: number = 0;

  aboutToAppear(): void {
    this.reload();
  }

  /** 重算广播（创建/取消计划、课表/参数变更）→ 重新读列表（状态与 conflict_hint 同步）。 */
  onRecomputeChanged(): void {
    this.reload();
  }

  reload(): void {
    ScheduleRepo.listActivePlans().then((rows: PlanRow[]) => {
      this.plans = rows;
      this.loading = false;
    }).catch(() => {
      this.plans = [];
      this.loading = false;
    });
  }

  /** 解析 conflict_hint（{"altStart":..,"altEnd":..}）→ "替代窗口：M月d日 HH:mm–HH:mm"。 */
  altHint(p: PlanRow): string {
    if (p.status !== 'CONFLICT' || p.conflictHint === '') {
      return '';
    }
    try {
      const o = JSON.parse(p.conflictHint) as Record<string, number>;
      const s = Number(o['altStart']);
      const e = Number(o['altEnd']);
      if (s <= 0 || e <= 0) {
        return '';
      }
      return '替代窗口：' + DateLabel.md(Math.floor(s / 1440)) + ' ' + DateLabel.hm(s) + '–' + DateLabel.hm(e);
    } catch (err) {
      return '';
    }
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

  /** 点击计划 → 操作弹窗。 */
  onPlanTap(p: PlanRow): void {
    this.getUIContext().showAlertDialog({
      title: p.title,
      message: planKindLabel(p.kind) + ' · ' + DateLabel.mdw(Math.floor(p.start / 1440)) + ' '
        + DateLabel.hm(p.start) + '—' + DateLabel.hm(p.end),
      primaryButton: {
        value: '取消计划',
        action: () => this.confirmCancel(p)
      },
      secondaryButton: {
        value: '关闭',
        action: () => {
        }
      }
    });
  }

  /** 取消计划二次确认。 */
  confirmCancel(p: PlanRow): void {
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

  async doCancel(p: PlanRow): Promise<void> {
    if (this.cancelling) {
      return;
    }
    this.cancelling = true;
    try {
      await PlanUseCase.cancelPlan(p.id);
      promptAction.showToast({ message: '已取消计划，该时段恢复空闲' });
      this.reload();
    } catch (e) {
      promptAction.showToast({ message: '取消失败：' + (e as Error).message });
    }
    this.cancelling = false;
  }

  build() {
    List({ space: 12 }) {
      if (!this.embedded) {
        ListItem() {
          Text('共同计划').fontSize(22).fontWeight(FontWeight.Bold)
            .margin({ top: 16, bottom: 4 }).width('100%')
        }
      }

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
            Text('还没有计划').fontSize(16).fontWeight(FontWeight.Medium)
            Text($r('app.string.plans_empty_desc'))
              .fontSize(12).fontColor($r('app.color.text_tertiary')).textAlign(TextAlign.Center)
            Button('去选一个窗口创建计划')
              .backgroundColor($r('app.color.brand_pink'))
              .borderRadius(22).height(44)
              .onClick(() => {
                if (this.onGoWindow != null) {
                  this.onGoWindow();
                } else {
                  navToCoTime();
                }
              })
          }
          .alignItems(HorizontalAlign.Center)
          .width('100%').padding({ top: 36, bottom: 36, left: 24, right: 24 }).borderRadius(20)
          .backgroundColor($r('app.color.brand_pink_bg'))
        }
      } else {
        // Repeat（API 26 稳定）替代 ForEach：键值 diff 更高效，行为一致
        Repeat<PlanRow>(this.plans)
          .key((p: PlanRow) => p.id + '-' + p.status + '-' + p.conflictHint)
          .each((ri: RepeatItem<PlanRow>) => {
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
    .padding(this.embedded ? 0 : 16)
    .width('100%').height('100%')
  }

  /** 左滑露出的"取消计划"按钮（点击走原有二次确认弹窗）。 */
  @Builder
  cancelSwipe(p: PlanRow) {
    Row() {
      Text('取消计划').fontSize(14).fontColor('#FFFFFF')
    }
    .width(88)
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor($r('app.color.danger_red'))
    .borderRadius(14)
    .onClick(() => this.confirmCancel(p))
  }

  /** 计划卡片：状态竖条 + 标题/类型/时间 + 状态（冲突红点 + 替代窗口提示）。 */
  @Builder
  planCard(p: PlanRow) {
    Row({ space: 12 }) {
      Column().width(4).height(40).borderRadius(2)
        .backgroundColor(p.status === 'CONFLICT'
          ? $r('app.color.danger_red')
          : (p.status === 'CANCELLED' ? $r('app.color.text_hint') : $r('app.color.brand_pink')))
      Column({ space: 6 }) {
        Row() {
          Text(p.title).fontSize(15).fontWeight(FontWeight.Medium).layoutWeight(1)
          Row({ space: 4 }) {
            if (p.status === 'CONFLICT') {
              Circle().width(8).height(8).fill($r('app.color.danger_red'))
            }
            Text(this.statusLabel(p.status)).fontSize(12)
              .fontColor(this.statusColor(p.status))
          }
        }.width('100%')

        Text(planKindLabel(p.kind) + ' · ' + DateLabel.mdw(Math.floor(p.start / 1440)) + ' '
          + DateLabel.hm(p.start) + '—' + DateLabel.hm(p.end) + ' · '
          + DateLabel.duration(p.end - p.start))
          .fontSize(12).fontColor($r('app.color.text_tertiary'))

        if (p.status === 'CONFLICT') {
          Column({ space: 4 }) {
            Text('与最新课表/班表冲突，计划时间已不可用').fontSize(11).fontColor($r('app.color.danger_red'))
            if (this.altHint(p) !== '') {
              Text(this.altHint(p)).fontSize(12).fontColor($r('app.color.brand_pink'))
            } else {
              Text('未来暂无合适的替代窗口，可取消后手动调整').fontSize(11).fontColor($r('app.color.text_hint'))
            }
          }
          .width('100%')
          .padding({ top: 6, bottom: 6, left: 10, right: 10 })
          .borderRadius(8)
          .backgroundColor($r('app.color.danger_bg'))
          .alignItems(HorizontalAlign.Start)
        } else {
          Text('点击可取消计划').fontSize(11).fontColor($r('app.color.text_hint'))
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .width('100%').padding(16).borderRadius(20).backgroundColor($r('app.color.card_bg'))
    .shadow({ radius: 16, color: $r('app.color.shadow_soft'), offsetX: 0, offsetY: 4 })
    .onClick(() => this.onPlanTap(p))
  }
}
