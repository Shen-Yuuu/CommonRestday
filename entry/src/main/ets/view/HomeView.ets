import { Interval, MIN_PER_DAY, WindowTag, hasTagOf, todayEpochDay } from 'domain';
import { ScheduleRepo, SettingsStore } from 'data';
import { DateLabel, Logger } from 'commons';
import { ScheduleUseCase, SettingsStoreParams } from 'feature';
import { navToMe } from '../util/NavUtil';

/** 首页：先回答三个问题（今晚 / 下一个完整同休日 / 出行窗口），双语义——有伴侣读共同窗口，无伴侣显示"我的空闲"+ 添加伴侣引导。 */
@Component
export struct HomeView {
  @State loading: boolean = true;
  @State hasPartner: boolean = false;
  @State partnerNick: string = '';
  @State tonight: string = '';
  @State nextFullDay: string = '';
  @State nextTrip: string = '';
  @State windowCount: number = 0;
  @State horizonDays: number = 120;
  @StorageProp('recomputeCount') @Watch('onRecomputeChanged') recomputeCount: number = 0;

  aboutToAppear(): void {
    this.refresh();
  }

  /** 全量刷新：重算（毫秒级）后读缓存渲染。 */
  refresh(): void {
    this.loading = true;
    ScheduleUseCase.ensureSeeded().then(() => {
      return ScheduleUseCase.recompute(todayEpochDay());
    }).then(() => {
      return this.applyFromCache();
    }).catch((e: Error) => {
      Logger.error('HomeView', 'recompute failed: ' + e.message);
      this.loading = false;
    });
  }

  /** 重算广播（保存动作/伴侣档案变更）→ 只重读缓存。 */
  onRecomputeChanged(): void {
    this.applyFromCache();
  }

  async applyFromCache(): Promise<void> {
    try {
      const ivs: Interval[] = await ScheduleRepo.listWindows();
      this.hasPartner = await ScheduleUseCase.hasPartnerContext();
      try {
        const profile = SettingsStore.getPartnerProfile();
        this.partnerNick = profile != null ? profile.nick : '';
      } catch (e) {
        this.partnerNick = '';
      }
      // 视界从参数读取（修复硬编码 120）
      this.horizonDays = SettingsStoreParams().horizonDays;
      this.applyWindows(ivs);
    } catch (e) {
      // 读取失败保持既有展示
    }
    this.loading = false;
  }

  applyWindows(ivs: Interval[]): void {
    const today = todayEpochDay();
    const now = today * MIN_PER_DAY + this.minutesNow();
    // 未来窗口（过滤已过期）
    const future: Interval[] = [];
    for (let i = 0; i < ivs.length; i++) {
      if (ivs[i].end > now) {
        future.push(ivs[i]);
      }
    }
    this.windowCount = future.length;
    this.tonight = '';
    this.nextFullDay = '';
    this.nextTrip = '';
    const freeWord = this.hasPartner ? '共同有空' : '有空';

    // ① 今晚：今天窗口的当前时刻后剩余
    for (let i = 0; i < future.length; i++) {
      const w = future[i];
      if (this.tonight === '' && Math.floor(w.start / MIN_PER_DAY) === today && w.end > now + 60) {
        const s = Math.max(w.start, now);
        this.tonight = '今晚 ' + DateLabel.hm(s) + ' 后' + freeWord + ' ' + DateLabel.duration(w.end - s);
      }
    }

    // ② 下个完整同休日：第一个带 FULL_DAY 标签的窗口
    for (let i = 0; i < future.length; i++) {
      const w = future[i];
      if (hasTagOf(w.tag.split('|'), WindowTag.FULL_DAY)) {
        const d = Math.floor(w.start / MIN_PER_DAY);
        const diff = d - today;
        if (this.hasPartner) {
          this.nextFullDay = diff === 0
            ? '今天就是完整同休日（' + DateLabel.mdw(d) + '）'
            : '距离下一个完整同休日还有 ' + diff + ' 天（' + DateLabel.mdw(d) + '）';
        } else {
          this.nextFullDay = DateLabel.mdw(d) + '（还有 ' + diff + ' 天）';
        }
        break;
      }
    }

    // ③ 出行窗口：带 TRIP/OVERNIGHT_TRIP 标签的最长窗口
    let best: Interval | null = null;
    for (let i = 0; i < future.length; i++) {
      const w = future[i];
      const tags = w.tag.split('|');
      if (hasTagOf(tags, WindowTag.TRIP) || hasTagOf(tags, WindowTag.OVERNIGHT_TRIP)) {
        if (best == null || w.end - w.start > best.end - best.start) {
          best = w;
        }
      }
    }
    if (best != null) {
      const sd = Math.floor(best.start / MIN_PER_DAY);
      const ed = Math.floor((best.end - 1) / MIN_PER_DAY);
      if (this.hasPartner) {
        this.nextTrip = DateLabel.md(sd) + '–' + DateLabel.md(ed) + ' 适合安排旅行';
      } else {
        this.nextTrip = DateLabel.mdw(sd) + ' 起，连续 ' + DateLabel.duration(best.end - best.start) + '，适合安排出行';
      }
    }

    if (this.tonight === '') {
      this.tonight = '今晚暂无 ≥1 小时的空闲窗口';
    }
  }

  minutesNow(): number {
    const d = new Date();
    return d.getHours() * 60 + d.getMinutes();
  }

  /** 按小时段问候语。 */
  greeting(): string {
    const h = new Date().getHours();
    if (h >= 5 && h < 11) {
      return '早上好';
    }
    if (h < 13) {
      return '中午好';
    }
    if (h < 18) {
      return '下午好';
    }
    if (h < 23) {
      return '晚上好';
    }
    return '夜深了';
  }

  build() {
    Scroll() {
      Column({ space: 12 }) {
        Text(this.greeting()).fontSize(28).fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
          .margin({ top: 20 })

        Text(DateLabel.mdw(todayEpochDay()) + (this.hasPartner && this.partnerNick !== ''
          ? ' · 我 ❤ ' + this.partnerNick
          : ''))
          .fontSize(13).fontColor($r('app.color.text_tertiary'))
          .margin({ top: 2 })

        if (this.loading) {
          Text($r('app.string.computing')).fontSize(14).fontColor($r('app.color.text_tertiary')).margin({ top: 40 })
        } else {
          // 渐变主卡：今晚结论（白字，固定渐变不随深浅色变化）
          Column({ space: 8 }) {
            Text('今晚').fontSize(13).fontColor('#FFFFFFB8')
            Text(this.tonight).fontSize(20).fontWeight(FontWeight.Medium).fontColor('#FFFFFF')
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')
          .padding(20)
          .borderRadius(24)
          .linearGradient({
            angle: 135,
            colors: [[$r('app.color.sunset_from'), 0], [$r('app.color.sunset_to'), 1]]
          })
          .shadow({ radius: 16, color: $r('app.color.shadow_soft'), offsetX: 0, offsetY: 4 })

          // 次级卡：下一个完整同休日 + 出行窗口
          Column({ space: 12 }) {
            Row({ space: 10 }) {
              Column().width(4).height(34).borderRadius(2)
                .linearGradient({
                  angle: 180,
                  colors: [[$r('app.color.accent_purple'), 0], [$r('app.color.brand_pink'), 1]]
                })
              Column({ space: 2 }) {
                Text('下一个完整同休日').fontSize(12).fontColor($r('app.color.text_tertiary'))
                Text(this.nextFullDay === '' ? '未来视界内暂无，去调整班表或参数' : this.nextFullDay)
                  .fontSize(15).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary'))
              }.alignItems(HorizontalAlign.Start).layoutWeight(1)
            }.width('100%')

            Row({ space: 10 }) {
              Column().width(4).height(34).borderRadius(2)
                .linearGradient({
                  angle: 180,
                  colors: [[$r('app.color.info_blue'), 0], [$r('app.color.success_green'), 1]]
                })
              Column({ space: 2 }) {
                Text('出行窗口').fontSize(12).fontColor($r('app.color.text_tertiary'))
                Text(this.nextTrip === ''
                  ? (this.hasPartner ? '暂无出行窗口' : '未发现 ≥32 小时的连续空档')
                  : this.nextTrip)
                  .fontSize(15).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary'))
              }.alignItems(HorizontalAlign.Start).layoutWeight(1)
            }.width('100%')
          }
          .width('100%')
          .padding(18)
          .borderRadius(20)
          .backgroundColor($r('app.color.card_bg'))
          .shadow({ radius: 16, color: $r('app.color.shadow_soft'), offsetX: 0, offsetY: 4 })

          if (!this.hasPartner) {
            // 添加伴侣引导卡（US3 场景 2）
            Column({ space: 6 }) {
              Text('添加伴侣，找到你们的共同时间').fontSize(14).fontColor($r('app.color.brand_pink'))
                .fontWeight(FontWeight.Medium)
              Text('在本机代录 TA 的课表/班表，首页立即切换为「我们」模式')
                .fontSize(11).fontColor($r('app.color.brand_pink_muted'))
            }
            .alignItems(HorizontalAlign.Start)
            .width('100%').padding(16).borderRadius(20)
            .backgroundColor($r('app.color.brand_pink_bg'))
            .onClick(() => navToMe())
          }

          Row({ space: 8 }) {
            Text('未来 ' + this.horizonDays + ' 天' + (this.hasPartner ? '共同窗口' : '空闲窗口')
              + '：' + this.windowCount + ' 个')
              .fontSize(12).fontColor($r('app.color.text_tertiary'))
            Blank()
            Text('刷新').fontSize(13).fontColor($r('app.color.brand_pink'))
              .onClick(() => this.refresh())
          }.width('100%').padding({ top: 4 })
        }
      }
      .padding(16)
      .width('100%')
    }
    .width('100%').height('100%')
    .backgroundColor($r('app.color.page_bg_warm'))
    .align(Alignment.Top)
  }
}
