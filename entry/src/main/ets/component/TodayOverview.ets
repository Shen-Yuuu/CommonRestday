import { DesignTokens } from '../theme/DesignTokens';
import { AccessibilityPolicy } from '../accessibility/AccessibilityPolicy';
import { EditorialCard } from './EditorialCard';
import { TodayAgendaItem } from 'feature';
import { LocalTween } from '../util/LocalTween';

/** @Builder 传两个及以上参数时不参与动态渲染（ArkUI 限制），所以整行合成一个对象字面量按引用传。 */
interface BusyLineArg {
  who: string;
  text: string;
  dot: Resource;
}

interface AgendaRowArg {
  item: TodayAgendaItem;
  separated: boolean;
}

/**
 * 今日双方概览：我 / TA / 共同三行忙碌与空闲摘要，加两个下一步动作。
 * 三行文本全部来自读模型（含对方隐私等级造成的粗粒度表述），页面不重算、不改写。
 */
@Component
export struct TodayOverview {
  @Prop myText: string = '';
  @Prop partnerText: string = '';
  @Prop commonText: string = '';
  /** 单人形态不显示 TA 行（此时 partnerText 是"未知"，展示出来只会造成误解）。 */
  @Prop partnerVisible: boolean = false;
  @Prop partnerName: string = '';
  @Prop weekdayText: string = '';
  @Prop agenda: TodayAgendaItem[] = [];
  @Prop agendaFailed: boolean = false;
  @State private agendaExpanded: boolean = false;
  @State private agendaProgress: number = 0;
  @State private extraAgendaHeight: number = 0;
  private agendaTween: LocalTween = new LocalTween();
  @StorageProp('crd_reduce_motion') reduceMotion: boolean = false;
  onEditSchedule: () => void = () => {};
  onAddPlan: () => void = () => {};
  // 装饰器实参必须是字面量，取值与 SENIOR_MODE_KEY 保持一致。
  @StorageProp('crd_senior_mode') senior: boolean = false;
  /** 两颗胶囊共用一个焦点位：-1 表示没有键盘焦点，0/1 是画焦点环的那一颗。 */
  @State private focusedPill: number = -1;

  private visibleAgenda(): TodayAgendaItem[] {
    return this.agenda.slice(0, 3);
  }

  aboutToDisappear(): void {
    this.agendaTween.cancel();
  }

  private toggleAgenda(): void {
    this.agendaExpanded = !this.agendaExpanded;
    const target = this.agendaExpanded ? 1 : 0;
    this.agendaTween.play(this.getUIContext(), this.agendaProgress, target,
      DesignTokens.motion(this.reduceMotion, Math.round(180 * Math.abs(target - this.agendaProgress))),
      (progress: number) => { this.agendaProgress = progress; });
  }

  private agendaColor(kind: string): Resource {
    return kind === 'PLAN' ? DesignTokens.primary : (kind === 'COURSE' ? DesignTokens.info : DesignTokens.accent);
  }

  private agendaKind(kind: string): string {
    return kind === 'PERSONAL' ? '个人安排' : kind === 'PLAN' ? '计划' : (kind === 'COURSE' ? '课程' : (kind === 'SHIFT_COMMUTE' ? '班次·含通勤' : '班次'));
  }

  @Builder
  agendaRow(row: AgendaRowArg) {
    Column() {
      if (row.separated) {
        Divider().strokeWidth(0.5).color(DesignTokens.divider)
          .margin({ top: 12, bottom: 12 }).accessibilityLevel('no')
      }
      Row({ space: 14 }) {
        Column({ space: 3 }) {
          Text(row.item.startText)
            .fontSize(DesignTokens.fontCaption).fontColor(DesignTokens.textSecondary)
            .width('100%').textAlign(TextAlign.Center)
          Column({ space: 3 }) {
            Column().width(1).height(7).backgroundColor(this.agendaColor(row.item.kind))
            Circle().width(7).height(7).fill(Color.Transparent)
              .stroke(this.agendaColor(row.item.kind)).strokeWidth(1.5)
            Column().width(1).height(7).backgroundColor(this.agendaColor(row.item.kind))
          }.width('100%').opacity(0.65).accessibilityLevel('no')
          Text(row.item.endText)
            .fontSize(DesignTokens.fontCaption).fontColor(DesignTokens.textSecondary)
            .width('100%').textAlign(TextAlign.Center)
        }.width(64)
        Column({ space: 6 }) {
          Text(row.item.name).fontSize(DesignTokens.fontBody).fontWeight(600)
            .fontColor(DesignTokens.textPrimary).width('100%')
          Text(this.agendaKind(row.item.kind))
            .fontSize(DesignTokens.fontCaption).fontColor(DesignTokens.textSecondary)
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      }.width('100%').alignItems(VerticalAlign.Center)
        .accessibilityGroup(true)
        .accessibilityText(row.item.timeText + '，' + row.item.name + '，' + this.agendaKind(row.item.kind))
    }.width('100%')
  }

  @Builder
  agendaList() {
    Column() {
      ForEach(this.visibleAgenda(), (item: TodayAgendaItem, index: number) => {
        this.agendaRow({ item: item, separated: index > 0 })
      }, (item: TodayAgendaItem) => item.id + '|' + item.timeText + '|' + item.name + '|' + item.kind)
      if (this.agenda.length > 3) {
        // Scroll 只提供无界的内容测量，禁止滚动交互；高度来自内容而不是外层标题。
        Scroll() {
          Column() {
            ForEach(this.agenda.slice(3), (item: TodayAgendaItem) => {
              this.agendaRow({ item: item, separated: true })
            }, (item: TodayAgendaItem) => item.id + '|' + item.timeText + '|' + item.name + '|' + item.kind)
          }.width('100%').alignItems(HorizontalAlign.Start)
          .onAreaChange((_old: Area, area: Area) => {
            const height = Number(area.height);
            if (Number.isFinite(height) && Math.abs(height - this.extraAgendaHeight) > 0.5) {
              this.extraAgendaHeight = height;
            }
          })
        }
        .width('100%').height(this.extraAgendaHeight * this.agendaProgress)
        .scrollBar(BarState.Off).enableScrollInteraction(false).clip(true)
        .opacity(this.agendaProgress)
        .accessibilityLevel(this.agendaProgress === 0 ? 'no-hide-descendants' : 'auto')
        Button() {
          Row({ space: 6 }) {
            Text(this.agendaExpanded ? '收起今日安排' : '展开今日安排（' + this.agenda.length + '）')
              .fontSize(DesignTokens.fontCaption).fontColor(DesignTokens.textAccent)
            SymbolGlyph($r('sys.symbol.chevron_down'))
              .fontSize(12).fontColor([DesignTokens.textAccent])
              .rotate({ angle: this.agendaProgress * 180 })
              .accessibilityLevel('no')
          }.justifyContent(FlexAlign.Center).width('100%')
        }
          .width('100%').constraintSize({ minHeight: AccessibilityPolicy.minHit(this.senior) })
          .backgroundColor(DesignTokens.fillWeakest).stateEffect(false)
          .accessibilityText(this.agendaExpanded ? '收起今日安排' : '展开今日安排，共' + this.agenda.length + '条')
          .onClick(() => this.toggleAgenda())
      }
    }.width('100%').alignItems(HorizontalAlign.Start).margin({ top: 14 })
  }

  @Builder
  busyLine(row: BusyLineArg) {
    Row({ space: DesignTokens.space2 }) {
      Circle()
        .width(DesignTokens.space2)
        .height(DesignTokens.space2)
        .fill(row.dot)
        // 我 / TA 已经在紧邻的文字里，圆点只是颜色分区，不再朗读一遍
        .accessibilityLevel('no')
      Text(row.who)
        .fontSize(DesignTokens.fontCaption)
        .fontColor(DesignTokens.textSecondary)
        .width(40)
      Text(row.text)
        .fontSize(DesignTokens.fontCaption)
        .fontColor(DesignTokens.textPrimary)
        .layoutWeight(1)
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .margin({ top: DesignTokens.space2 })
  }

  build() {
    EditorialCard({ hero: false, cutTopLeft: false, tappable: false }) {
      Row() {
        Text('今天')
          .fontSize(DesignTokens.fontTitle)
          .fontFamily(DesignTokens.fontRound)
          .fontWeight(FontWeight.Bolder)
          .fontColor(DesignTokens.textPrimary)
          .layoutWeight(1)
        Text(this.weekdayText)
          .fontSize(DesignTokens.fontCaption)
          .fontColor(DesignTokens.textTertiary)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      this.busyLine({ who: '我', text: this.myText, dot: DesignTokens.busyMine })
      if (this.partnerVisible) {
        this.busyLine({
          who: this.partnerName === '' ? 'TA' : this.partnerName,
          text: this.partnerText,
          dot: DesignTokens.busyPartner
        })
      }

      Text(this.commonText)
        .fontSize(DesignTokens.fontCaption)
        .fontColor(DesignTokens.textAccent)
        .fontWeight(700)
        .width('100%')
        .padding({
          left: DesignTokens.space3,
          right: DesignTokens.space3,
          top: DesignTokens.space2,
          bottom: DesignTokens.space2
        })
        .borderRadius(DesignTokens.radiusPill)
        .backgroundColor(DesignTokens.primaryBg)
        .margin({ top: DesignTokens.space3 })

      if (this.agendaFailed) {
        Text('今天的安排暂时没读出来，下拉刷新再试。')
          .fontSize(DesignTokens.fontCaption).fontColor(DesignTokens.textSecondary)
          .margin({ top: DesignTokens.space3 })
      } else if (this.agenda.length > 0) {
        this.agendaList()
      }

      Row({ space: DesignTokens.space2 }) {
        this.actionPill(0, '＋ 日程', '添加个人日程或调整工作排班', false, () => {
          this.onEditSchedule();
        })
        this.actionPill(1, '＋ 计划', '添加计划', true, () => {
          this.onAddPlan();
        })
      }
      .width('100%')
      .margin({ top: DesignTokens.space3 })
    }
  }

  /** 胶囊动作：文字当按钮用时要自己补齐热区、焦点环与可朗读名（原生 Text 不带这些）。 */
  @Builder
  actionPill(idx: number, label: string, readAs: string, primary: boolean, onTap: () => void) {
    Text(label)
      .fontSize(DesignTokens.fontCaption)
      .fontColor(primary ? DesignTokens.heroText : DesignTokens.textSecondary)
      .fontWeight(700)
      .textAlign(TextAlign.Center)
      .padding({ left: DesignTokens.space3, right: DesignTokens.space3 })
      .constraintSize({ minHeight: AccessibilityPolicy.minHit(this.senior) })
      .borderRadius(DesignTokens.radiusPill)
      .backgroundColor(primary ? DesignTokens.primary : DesignTokens.fillWeak)
      // 主操作给一条果冻厚底；次操作是浅底芯片，不需要下沿
      .shadow(primary ? DesignTokens.jelly(DesignTokens.primaryDeep, DesignTokens.jellyDepth) : undefined)
      // 焦点环常驻 2vp 透明边，聚焦时不跳动（与首页答案行同一口径）。
      .border({
        width: 2,
        color: this.focusedPill === idx ? DesignTokens.focusRing : Color.Transparent,
        radius: DesignTokens.radiusPill
      })
      .layoutWeight(1)
      .focusable(true)
      .accessibilityText(readAs)
      .onFocus(() => {
        this.focusedPill = idx;
      })
      .onBlur(() => {
        this.focusedPill = -1;
      })
      .clickEffect(DesignTokens.tapChip())
      .onClick(onTap)
  }
}
