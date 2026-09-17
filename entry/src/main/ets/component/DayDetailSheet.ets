import { Interval, MIN_PER_DAY } from 'domain';
import { DateLabel } from 'commons';
import { DayViewData, ScheduleUseCase } from 'feature';
import { SubHeaderV2, SubHeaderV2Title } from '@kit.ArkUI';
import { busyTagLabel, tagColor, tagLabel } from '../util/WindowTagUtil';

/** 时间轴条分段（顺序排列，宽度百分比之和 = 100）。 */
interface BarSeg {
  pct: number;
  busy: boolean;
}

/**
 * 日详情半模态（C2 月历点日期进入）：
 * - 当日共同窗口列表（点击 → 交由父页打开 WindowDetailSheet 创建计划）；
 * - 我的忙碌时间轴（比例条 + 明细行）；
 * - 对方忙碌时间轴：按来源与隐私等级差异化渲染——
 *   LOCAL 全量细节；SNAPSHOT L1 仅"忙"（30 分钟粒度）、L2 量化时段、L3 精确时段。
 */
@Component
export struct DayDetailSheet {
  @Prop day: number = 0;
  /** 点击某个共同窗口：父页收回本 sheet 并打开创建计划 sheet。 */
  onPickWindow: (start: number, end: number, tags: string) => void = () => {
  };
  onClose: () => void = () => {
  };
  @State data: DayViewData | null = null;
  @State loading: boolean = true;

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

  build() {
    Column({ space: 14 }) {
      Row() {
        Text(DateLabel.mdw(this.day)).fontSize(18).fontWeight(FontWeight.Bold)
        Blank()
        Text('关闭').fontSize(14).fontColor($r('app.color.text_secondary'))
          .onClick(() => this.onClose())
      }.width('100%')

      if (this.loading) {
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
            // ---------- 当日共同窗口 ----------
            Column({ space: 8 }) {
              SubHeaderV2({ title: new SubHeaderV2Title({ primaryTitle: '当日共同窗口' }) })
              if (this.data.windows.length === 0) {
                Text('当天没有共同空闲窗口').fontSize(12).fontColor($r('app.color.text_tertiary'))
              } else {
                ForEach(this.data.windows, (w: Interval) => {
                  Row({ space: 8 }) {
                    Column({ space: 2 }) {
                      Text(DateLabel.hm(w.start) + ' – ' + DateLabel.hm(w.end)
                        + ' · ' + DateLabel.duration(w.end - w.start))
                        .fontSize(13).fontColor($r('app.color.text_primary'))
                      if (w.tag !== '') {
                        Row({ space: 4 }) {
                          ForEach(w.tag.split('|'), (t: string) => {
                            Text(tagLabel(t))
                              .fontSize(10).fontColor('#FFFFFF')
                              .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                              .borderRadius(8).backgroundColor(tagColor(t))
                          }, (t: string) => t)
                        }
                      }
                    }.alignItems(HorizontalAlign.Start).layoutWeight(1)
                    Text('去计划 ›').fontSize(12).fontColor($r('app.color.brand_pink'))
                  }
                  .width('100%').padding(10).borderRadius(10)
                  .backgroundColor($r('app.color.fill_weakest'))
                  .onClick(() => this.onPickWindow(w.start, w.end, w.tag))
                }, (w: Interval) => '' + w.start + '-' + w.end)
              }
            }.width('100%')

            // ---------- 我的忙碌 ----------
            Column({ space: 8 }) {
              SubHeaderV2({ title: new SubHeaderV2Title({ primaryTitle: '我的忙碌' }) })
              this.busyBar(this.segmentsOf(this.clipped(this.data.myBusy)), $r('app.color.my_busy'))
              this.busyList(this.clipped(this.data.myBusy))
            }.width('100%')

            // ---------- TA 的忙碌 ----------
            Column({ space: 8 }) {
              SubHeaderV2({ title: new SubHeaderV2Title({ primaryTitle: 'TA 的忙碌' }) })
              if (this.data.partnerBusy == null) {
                Text('暂无对方数据（当前为单人模式）')
                  .fontSize(12).fontColor($r('app.color.text_tertiary'))
              } else {
                Text(this.partnerNote()).fontSize(11).fontColor($r('app.color.text_hint'))
                this.busyBar(this.segmentsOf(this.clipped(this.data.partnerBusy)), $r('app.color.partner_busy'))
                this.busyList(this.clipped(this.data.partnerBusy))
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
    .backgroundColor($r('app.color.page_bg_warm'))
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
        }, (iv: Interval) => '' + iv.start + '-' + iv.end + iv.tag)
      }.width('100%')
    }
  }
}
