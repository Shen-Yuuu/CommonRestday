import { Interval, MIN_PER_DAY, OWNER_ME, Window, WindowChannel } from 'domain';
import { DateLabel } from 'commons';
import { CommonTimeQueryService, DayViewData, ScheduleUseCase, WindowSummary } from 'feature';
import { SubHeaderV2, SubHeaderV2Title } from '@kit.ArkUI';
import { busyTagLabel, displayTagLabel, tagColor } from '../util/WindowTagUtil';
import { DesignTokens } from '../theme/DesignTokens';
import { AccessibilityPolicy } from '../accessibility/AccessibilityPolicy';
import { DayShiftSheet } from './DayShiftSheet';

/** 时间轴条分段（顺序排列，宽度百分比之和 = 100）。 */
interface BarSeg {
  pct: number;
  busy: boolean;
}

/**
 * 日详情半模态（周历点某一天进入）：先看再改。
 * - 页头右侧「改这天」切到 DayShiftSheet（单日覆盖），完成或返回即回到本页并重新取数；
 * - 当日窗口列表（点击 → 交由父页打开 WindowDetailSheet 创建计划）；
 *   只列常规通道，旅行通道单列一行：两个通道在同一段时间各产出一个窗口，
 *   混在一起会把同一晚算成两段共同时间；
 * - 我的忙碌时间轴（比例条 + 明细行）；
 * - 对方忙碌时间轴：按来源与隐私等级差异化渲染——
 *   LOCAL 全量细节；SNAPSHOT L1 仅"忙"（30 分钟粒度）、L2 量化时段、L3 精确时段。
 * 比例条画 myBusy/partnerBusy（含作息，语义是"这段时间不能安排"），
 * 明细行只列真忙 myTrueBusy/partnerTrueBusy，否则睡眠会被念成忙碌（D-23）。
 * 标签压缩与文案口径由 CommonTimeQueryService.summaryOf 给出，页面不自行映射领域标签。
 */
@Component
export struct DayDetailSheet {
  @Prop day: number = 0;
  /** 「改这天」写哪一侧的班表：共同时间页看的是"我"的排班，故默认我。 */
  @Prop owner: string = OWNER_ME;
  /** 点击某个共同窗口：父页收回本 sheet 并打开创建计划 sheet。 */
  onPickWindow: (start: number, end: number, tags: string[]) => void = () => {
  };
  onClose: () => void = () => {
  };
  @State data: DayViewData | null = null;
  @State loading: boolean = true;
  /** 二级态：true 时整页换成 DayShiftSheet，本组件的取数逻辑不动。 */
  @State editing: boolean = false;
  // 装饰器实参必须是字面量，取值与 SENIOR_MODE_KEY 保持一致。
  @StorageProp('crd_senior_mode') senior: boolean = false;

  /** 窗口行的朗读文本：时刻 + 时长 + 展示标签 + 点击后果（标签此前只有颜色区分）。 */
  private windowRead(w: WindowSummary): string {
    let s = DateLabel.hm(w.start) + ' 到 ' + DateLabel.hm(w.end) + '，' + DateLabel.duration(w.durationMin);
    if (w.displayTags.length > 0) {
      s += '，' + w.displayTags.map((t: string): string => displayTagLabel(t)).join('、');
    }
    return s + '，点击去计划';
  }

  aboutToAppear(): void {
    this.load();
  }

  async load(): Promise<void> {
    this.loading = true;
    try {
      this.data = await ScheduleUseCase.getDayView(this.day);
    } catch (e) {
      this.data = null;
    }
    this.loading = false;
  }

  dayStart(): number {
    return this.day * MIN_PER_DAY;
  }

  /** 当日窗口按通道分流，并转成读模型（展示标签、标题、副标题都由服务给）。 */
  private windowsOf(channel: WindowChannel): WindowSummary[] {
    const out: WindowSummary[] = [];
    const d = this.data;
    if (d == null) {
      return out;
    }
    for (let i = 0; i < d.windows.length; i++) {
      const w: Window = d.windows[i];
      if (w.channel !== channel) {
        continue;
      }
      out.push(CommonTimeQueryService.summaryOf(w));
    }
    out.sort((a: WindowSummary, b: WindowSummary): number => a.start - b.start);
    return out;
  }

  private regularWindows(): WindowSummary[] {
    return this.windowsOf(WindowChannel.REGULAR);
  }

  private tripWindows(): WindowSummary[] {
    return this.windowsOf(WindowChannel.TRIP);
  }

  /** 区间列表与当日的交集（裁剪到日内）。 */
  clipped(ivs: Interval[] | null): Interval[] {
    const out: Interval[] = [];
    if (ivs == null) {
      return out;
    }
    const s = this.dayStart();
    const e = s + MIN_PER_DAY;
    for (let i = 0; i < ivs.length; i++) {
      const cs = Math.max(ivs[i].start, s);
      const ce = Math.min(ivs[i].end, e);
      if (ce > cs) {
        const iv: Interval = { start: cs, end: ce, tag: ivs[i].tag };
        out.push(iv);
      }
    }
    return out;
  }

  /** 忙碌比例条分段（gap/busy 交替，宽度百分比和 = 100）。 */
  segmentsOf(busy: Interval[]): BarSeg[] {
    const segs: BarSeg[] = [];
    const s = this.dayStart();
    const e = s + MIN_PER_DAY;
    let cur = s;
    for (let i = 0; i < busy.length; i++) {
      const bs = Math.max(busy[i].start, s);
      const be = Math.min(busy[i].end, e);
      if (bs > cur) {
        segs.push({ pct: (bs - cur) / MIN_PER_DAY * 100, busy: false });
      }
      if (be > bs) {
        segs.push({ pct: (be - bs) / MIN_PER_DAY * 100, busy: true });
      }
      if (be > cur) {
        cur = be;
      }
    }
    if (cur < e) {
      segs.push({ pct: (e - cur) / MIN_PER_DAY * 100, busy: false });
    }
    return segs;
  }

  /** 对方数据来源/隐私等级说明。 */
  partnerNote(): string {
    if (this.data == null || this.data.partnerBusy == null) {
      return '';
    }
    if (this.data.partnerSource === 'LOCAL') {
      return '来源：本机代录（完整时段）';
    }
    if (this.data.partnerShareLevel === 1) {
      return '来源：加密快照 · 对方仅共享忙闲状态';
    }
    if (this.data.partnerShareLevel === 2) {
      return '来源：加密快照 · 对方共享忙碌类型（30 分钟精度）';
    }
    return '来源：加密快照 · 对方共享完整时段';
  }

  /** 单人态下这些窗口就是"我的空闲"，不该谎称共同（与页头口径一致，D-23 顺手收敛）。 */
  private hasPartner(): boolean {
    return this.data != null && this.data.partnerBusy != null;
  }

  /** 页头下方的摘要行：段数与空闲总时长只算当日常规通道，旅行窗口跨整天不掺进来。 */
  private windowLead(): string {
    const wins: WindowSummary[] = this.regularWindows();
    const head = this.hasPartner() ? '当日共同窗口' : '当日我的空闲';
    if (wins.length === 0) {
      return head + ' 0 段';
    }
    return head + ' ' + wins.length + ' 段 · 空闲 ' + DateLabel.duration(this.totalMinOf(wins));
  }

  /** 忙碌区标题的括号部分：给出总时长，读的人不用自己加明细行。 */
  private busyTitle(label: string, ivs: Interval[] | null): string {
    const mins = this.clippedTotal(ivs);
    return mins > 0 ? label + '（共 ' + DateLabel.duration(mins) + '）' : label;
  }

  private totalMinOf(wins: WindowSummary[]): number {
    let m = 0;
    for (let i = 0; i < wins.length; i++) {
      m += wins[i].durationMin;
    }
    return m;
  }

  private clippedTotal(ivs: Interval[] | null): number {
    const list = this.clipped(ivs);
    let m = 0;
    for (let i = 0; i < list.length; i++) {
      m += list[i].end - list[i].start;
    }
    return m;
  }

  /** 从「改这天」返回概览：改班立刻重算共同时间，不重新取数会把刚改的这天念成旧样子。 */
  private backToOverview(): void {
    this.editing = false;
    this.load();
  }

  build() {
    Column({ space: 14 }) {
      Row() {
        Text(DateLabel.mdw(this.day)).fontSize(18).fontWeight(FontWeight.Bold)
        Blank()
        if (this.editing) {
          Text('返回概览').fontSize(14).fontColor($r('app.color.text_secondary'))
            .fontWeight(FontWeight.Bold)
            .padding({ left: 12, right: 12, top: 6, bottom: 6 })
            .borderRadius(DesignTokens.radiusPill).backgroundColor($r('app.color.fill_weakest'))
            .constraintSize({ minWidth: AccessibilityPolicy.minHit(this.senior), minHeight: AccessibilityPolicy.minHit(this.senior) })
            .focusable(true)
            .accessibilityText('返回当日概览')
            .onClick(() => this.backToOverview())
        } else {
          Text('改这天').fontSize(14).fontColor($r('app.color.brand_pink'))
            .fontWeight(FontWeight.Bold)
            .padding({ left: 12, right: 12, top: 6, bottom: 6 })
            .borderRadius(DesignTokens.radiusPill).backgroundColor($r('app.color.fill_weakest'))
            .constraintSize({ minWidth: AccessibilityPolicy.minHit(this.senior), minHeight: AccessibilityPolicy.minHit(this.senior) })
            .focusable(true)
            .accessibilityText('改这天的班，只影响这一天')
            .onClick(() => {
              this.editing = true;
            })
        }
        Text('关闭').fontSize(14).fontColor($r('app.color.text_secondary'))
          .margin({ left: 10 })
          .constraintSize({ minWidth: AccessibilityPolicy.minHit(this.senior), minHeight: AccessibilityPolicy.minHit(this.senior) })
          .focusable(true)
          .accessibilityText('关闭当日明细')
          .onClick(() => this.onClose())
      }.width('100%')

      if (this.editing) {
        Column() {
          DayShiftSheet({
            owner: this.owner,
            epochDay: this.day,
            onClose: () => {
              this.backToOverview();
            }
          })
        }
        .width('100%').layoutWeight(1)
      } else if (this.loading) {
        Column({ space: 8 }) {
          LoadingProgress().width(32).height(32).color($r('app.color.brand_pink'))
          Text('加载中…').fontSize(13).fontColor($r('app.color.text_tertiary'))
        }.width('100%').padding({ top: 24, bottom: 24 })
        .alignItems(HorizontalAlign.Center)
      } else if (this.data == null) {
        Text('数据加载失败，请稍后重试').fontSize(13).fontColor($r('app.color.text_tertiary'))
          .width('100%').textAlign(TextAlign.Center).padding({ top: 24, bottom: 24 })
      } else {
        Scroll() {
          Column({ space: 14 }) {
            Text(this.windowLead())
              .fontSize(13).fontColor($r('app.color.text_secondary')).width('100%')

            // ---------- 当日窗口 ----------
            Column({ space: 8 }) {
              if (this.regularWindows().length === 0) {
                Text(this.hasPartner() ? '当天没有共同空闲窗口' : '当天没有可安排的空闲')
                  .fontSize(12).fontColor($r('app.color.text_tertiary'))
              } else {
                ForEach(this.regularWindows(), (w: WindowSummary) => {
                  this.windowRow(w)
                }, (w: WindowSummary) => '' + w.start + '-' + w.end + '-' + w.channel)
              }
              ForEach(this.tripWindows(), (w: WindowSummary) => {
                this.tripRow(w)
              }, (w: WindowSummary) => 'trip-' + w.start + '-' + w.end)
            }.width('100%')

            // ---------- 我的忙碌 ----------
            Column({ space: 8 }) {
              SubHeaderV2({
                title: new SubHeaderV2Title({ primaryTitle: this.busyTitle('我的忙碌', this.data.myTrueBusy) })
              })
              this.busyBar(this.segmentsOf(this.clipped(this.data.myBusy)), $r('app.color.my_busy'))
              this.busyList(this.clipped(this.data.myTrueBusy))
            }.width('100%')

            // ---------- TA 的忙碌 ----------
            Column({ space: 8 }) {
              SubHeaderV2({
                title: new SubHeaderV2Title({
                  primaryTitle: this.busyTitle('TA 的忙碌', this.data.partnerTrueBusy)
                })
              })
              if (this.data.partnerBusy == null) {
                Text('暂无对方数据（当前为单人模式）')
                  .fontSize(12).fontColor($r('app.color.text_tertiary'))
              } else {
                Text(this.partnerNote()).fontSize(11).fontColor($r('app.color.text_hint'))
                this.busyBar(this.segmentsOf(this.clipped(this.data.partnerBusy)), $r('app.color.partner_busy'))
                this.busyList(this.clipped(this.data.partnerTrueBusy))
              }
            }.width('100%')
          }
          .width('100%')
        }
        .layoutWeight(1)
        .align(Alignment.Top)
        .scrollBar(BarState.Off)
      }
    }
    .width('100%')
    .height('100%')
    .padding({ left: 20, right: 20, top: 16, bottom: 24 })
    .backgroundColor(DesignTokens.page)
    // 02 的 .sheet 面是顶亮下页色的竖向渐变，不是一块平色（与另两张自绘 sheet 同一份配方）
    .linearGradient(DesignTokens.sheetGradient())
  }

  /** 常规通道窗口行：时刻 + 时长 + 压缩后的展示标签，点击交给父页建计划。 */
  @Builder
  windowRow(w: WindowSummary) {
    Row({ space: 8 }) {
      Column({ space: 2 }) {
        Text(DateLabel.hm(w.start) + ' – ' + DateLabel.hm(w.end) + ' · ' + DateLabel.duration(w.durationMin))
          .fontSize(13).fontColor($r('app.color.text_primary'))
        if (w.displayTags.length > 0) {
          Row({ space: 4 }) {
            ForEach(w.displayTags, (t: string) => {
              Text(displayTagLabel(t))
                .fontSize(10).fontColor(DesignTokens.heroText)
                .fontWeight(FontWeight.Bold)
                .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                .borderRadius(DesignTokens.radiusPill).backgroundColor(tagColor(t))
            }, (t: string) => t)
          }
        }
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      Text('去计划 ›').fontSize(12).fontColor($r('app.color.brand_pink'))
    }
    .width('100%').padding(10).borderRadius(10)
    .backgroundColor($r('app.color.fill_weakest'))
    .constraintSize({ minHeight: AccessibilityPolicy.minHit(this.senior) })
    .focusable(true)
    .accessibilityGroup(true)
    .accessibilityText(this.windowRead(w))
    .onClick(() => this.onPickWindow(w.start, w.end, w.tags))
  }

  /** 旅行通道窗口跨日，只报日期范围与时长，不与当日窗口混排（否则同一晚会被算两次）。 */
  @Builder
  tripRow(w: WindowSummary) {
    Row({ space: 8 }) {
      Column({ space: 2 }) {
        Text('旅行窗口 · ' + DateLabel.mdw(Math.floor(w.start / MIN_PER_DAY)) + ' '
          + DateLabel.endLabel(w.start, w.end))
          .fontSize(12).fontColor($r('app.color.text_secondary'))
        Text('连续 ' + DateLabel.duration(w.durationMin) + '，夜间睡眠不计入忙碌')
          .fontSize(10).fontColor($r('app.color.text_hint'))
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      Text('去计划 ›').fontSize(12).fontColor($r('app.color.brand_pink'))
    }
    .width('100%').padding(10).borderRadius(10)
    .backgroundColor($r('app.color.fill_weakest'))
    .constraintSize({ minHeight: AccessibilityPolicy.minHit(this.senior) })
    .focusable(true)
    .accessibilityGroup(true)
    .accessibilityText('旅行窗口 ' + DateLabel.mdw(Math.floor(w.start / MIN_PER_DAY)) + ' '
      + DateLabel.endLabel(w.start, w.end) + '，连续 ' + DateLabel.duration(w.durationMin) + '，点击去计划')
    .onClick(() => this.onPickWindow(w.start, w.end, w.tags))
  }

  /** 忙碌比例条（gap/busy 顺序分段，宽度百分比布局）。 */
  @Builder
  busyBar(segs: BarSeg[], color: ResourceColor) {
    Row() {
      ForEach(segs, (seg: BarSeg, i: number) => {
        Column()
          .width(seg.pct + '%')
          .height(10)
          .backgroundColor(seg.busy ? color : $r('app.color.bar_gap'))
      }, (seg: BarSeg, i: number) => '' + i + (seg.busy ? 'b' : 'g') + seg.pct)
    }
    .width('100%')
    .height(10)
    .borderRadius(5)
    .clip(true)
    // 比例条是下方明细行的另一种画法，逐段朗读只会重复；读屏念明细即可
    .accessibilityLevel('no')
  }

  /** 忙碌明细行（起止 + 标签）。 */
  @Builder
  busyList(ivs: Interval[]) {
    if (ivs.length === 0) {
      Text('全天空闲').fontSize(12).fontColor($r('app.color.text_tertiary'))
    } else {
      Column({ space: 4 }) {
        ForEach(ivs, (iv: Interval) => {
          Row({ space: 8 }) {
            Text(DateLabel.hm(iv.start) + ' – ' + DateLabel.hm(iv.end))
              .fontSize(12).fontColor($r('app.color.text_secondary'))
            Text(busyTagLabel(iv.tag))
              .fontSize(10).fontColor($r('app.color.text_tertiary'))
          }.width('100%')
          // 时段和类型是一件事的两半，分两段念会听成两条记录
          .accessibilityGroup(true)
        }, (iv: Interval) => '' + iv.start + '-' + iv.end + iv.tag)
      }.width('100%')
    }
  }
}
