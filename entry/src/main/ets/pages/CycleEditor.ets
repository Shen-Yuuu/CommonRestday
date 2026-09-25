import { LengthMetrics, promptAction, router } from '@kit.ArkUI';
import { OWNER_ME, CycleTemplate, ShiftType, todayEpochDay } from 'domain';
import { ScheduleRepo } from 'data';
import { AppConst, DateLabel } from 'commons';
import { ScheduleCommandService, ScheduleUseCase } from 'feature';
import { ownerFromParams } from '../model/RouteParams';
import { DesignTokens } from '../theme/DesignTokens';
import { toastCommand } from '../util/CommandToast';

/**
 * 锚点可选范围。DatePicker 是稳定组件（API 8）：API 26 的 DatePickerComponent
 * 官方目录仍标 Beta，P0 不把它当唯一入口（改造文档 Task 5.2 规则）。
 */
const ANCHOR_RANGE_START: Date = new Date(2020, 0, 1);
const ANCHOR_RANGE_END: Date = new Date(2030, 11, 31);
const MS_PER_DAY: number = 86400000;
/** 序列里的"休"用空串表示：CycleExpander 对空串不生成班次实例，与单日覆盖清空同一口径。 */
const REST_IN_SEQ: string = '';
const REST_COLOR: string = '#B8C4CE';

/** 循环模板编辑：班次序列 + 锚点日期（owner 双侧复用）。 */
@Entry
@Component
struct CycleEditor {
  @State owner: string = OWNER_ME;
  @State types: ShiftType[] = [];
  @State seq: string[] = [];
  @State anchor: number = todayEpochDay();
  @State hasTemplate: boolean = false;
  // 锚点日期 sheet（稳定 DatePicker，API 8）：sheet 内的临时选择值，确认才落锚
  @State anchorSheetVisible: boolean = false;
  @State anchorPick: Date = new Date();

  aboutToAppear(): void {
    this.owner = ownerFromParams(router.getParams());
    ScheduleUseCase.ensureSeeded(this.owner).then(() => {
      return ScheduleRepo.listShiftTypes(this.owner);
    }).then((list: ShiftType[]) => {
      this.types = list;
      return ScheduleRepo.getTemplate(this.owner);
    }).then((tpl: CycleTemplate | null) => {
      if (tpl != null) {
        this.seq = tpl.seq.slice();
        this.anchor = tpl.anchorEpochDay;
        this.hasTemplate = true;
      }
    }).catch(() => {
    });
  }

  typeName(id: string): string {
    if (id === REST_IN_SEQ) {
      return '休息';
    }
    for (let i = 0; i < this.types.length; i++) {
      if (this.types[i].id === id) {
        return this.types[i].name;
      }
    }
    return '?';
  }

  typeColor(id: string): string {
    if (id === REST_IN_SEQ) {
      return REST_COLOR;
    }
    for (let i = 0; i < this.types.length; i++) {
      if (this.types[i].id === id) {
        return this.types[i].color;
      }
    }
    return '#CCCCCC';
  }

  async save(): Promise<void> {
    if (this.seq.length === 0) {
      promptAction.showToast({ message: '请至少加入一天班次' });
      return;
    }
    const tpl: CycleTemplate = {
      id: 'main', name: this.owner === OWNER_ME ? '我的循环' : '伴侣循环',
      seq: this.seq.slice(), anchorEpochDay: this.anchor
    };
    const r = await ScheduleCommandService.saveTemplate(tpl, this.owner);
    if (r.changed) {
      this.hasTemplate = true;
    }
    toastCommand(r, '循环模板已保存，班表已自动展开');
  }

  /** 清空：已保存过模板时真删 DB（循环展开随之消失），并触发重算；未保存过仅重置编辑区。 */
  async clearTemplate(): Promise<void> {
    this.seq = [];
    if (!this.hasTemplate) {
      this.anchor = todayEpochDay();
      promptAction.showToast({ message: '已重置编辑区' });
      return;
    }
    this.getUIContext().showAlertDialog({
      message: '删除已保存的循环模板？删除后按循环展开的班表会全部消失。',
      primaryButton: {
        value: '取消',
        action: () => {
          this.reloadTemplate();
        }
      },
      secondaryButton: {
        value: '删除',
        fontColor: $r('app.color.brand_pink'),
        action: () => {
          this.doClearTemplate();
        }
      }
    });
  }

  async doClearTemplate(): Promise<void> {
    const r = await ScheduleCommandService.removeTemplate(this.owner);
    if (r.changed) {
      this.hasTemplate = false;
      this.anchor = todayEpochDay();
    } else {
      this.reloadTemplate();
    }
    toastCommand(r, '循环模板已删除');
  }

  /** 重新载入已保存模板（取消删除时恢复编辑区现场）。 */
  reloadTemplate(): void {
    ScheduleRepo.getTemplate(this.owner).then((tpl: CycleTemplate | null) => {
      if (tpl != null) {
        this.seq = tpl.seq.slice();
        this.anchor = tpl.anchorEpochDay;
        this.hasTemplate = true;
      }
    }).catch(() => {
    });
  }

  /** epochDay → 本地 Date：先按 UTC 拆出年月日，再按本地年月日建，避免时区把日期挪一天。 */
  private dateOf(ep: number): Date {
    const p = DateLabel.ymd(ep);
    return new Date(p.y, p.m - 1, p.d);
  }

  /** 本地 Date → epochDay：只取用户看到的年月日，按 UTC 归一，不受夏令时影响。 */
  private epochOf(d: Date): number {
    return Math.floor(Date.UTC(d.getFullYear(), d.getMonth(), d.getDate()) / MS_PER_DAY);
  }

  /** 打开锚点日期 sheet：稳定 DatePicker 滚轮选值，确认才落锚。 */
  pickAnchor(): void {
    this.anchorPick = this.dateOf(this.anchor);
    this.anchorSheetVisible = true;
  }

  /** 确认锚点：把 sheet 中的临时选择值写回。 */
  confirmAnchor(): void {
    this.anchor = this.epochOf(this.anchorPick);
    this.anchorSheetVisible = false;
  }

  build() {
    Column() {
      Row() {
        Row({ space: 2 }) {
          SymbolGlyph($r('sys.symbol.chevron_left')).fontSize(16).fontColor([$r('app.color.brand_pink')])
          Text('返回').fontSize(15).fontColor($r('app.color.brand_pink'))
        }.onClick(() => router.back())
        Blank()
        Text(this.owner === OWNER_ME ? '循环模板' : '伴侣的循环模板')
          .fontSize(17).fontWeight(FontWeight.Bold)
        Blank()
        Text('清空').fontSize(15).fontColor($r('app.color.text_tertiary')).onClick(() => this.clearTemplate())
      }.width('100%').padding(12)

      Scroll() {
        Column({ space: 12 }) {
          Column({ space: 8 }) {
            Text('循环序列（点击班次追加，点击序列中的项移除）')
              .fontSize(12).fontColor($r('app.color.text_tertiary')).width('100%')
            Flex({ wrap: FlexWrap.Wrap, space: { main: LengthMetrics.vp(8), cross: LengthMetrics.vp(8) } }) {
              ForEach(this.types, (st: ShiftType) => {
                Text(st.name)
                  .fontSize(13).fontColor(DesignTokens.heroText)
                  .fontWeight(FontWeight.Bold)
                  .padding({ left: 12, right: 12, top: 6, bottom: 6 })
                  .borderRadius(DesignTokens.radiusPill).backgroundColor(st.color)
                  .onClick(() => this.seq.push(st.id))
              }, (st: ShiftType) => st.id)
              // 休息不在班次类型表里，但「白白休」这类循环必须能直接排出来
              Text('休息')
                .fontSize(13).fontColor(DesignTokens.heroText)
                .fontWeight(FontWeight.Bold)
                .padding({ left: 12, right: 12, top: 6, bottom: 6 })
                .borderRadius(DesignTokens.radiusPill).backgroundColor(REST_COLOR)
                .onClick(() => this.seq.push(REST_IN_SEQ))
            }.width('100%')

            if (this.seq.length === 0) {
              Text('序列为空').fontSize(13).fontColor($r('app.color.text_disabled'))
                .width('100%').textAlign(TextAlign.Center).padding(12)
            } else {
              Flex({ wrap: FlexWrap.Wrap, space: { main: LengthMetrics.vp(6), cross: LengthMetrics.vp(6) } }) {
                ForEach(this.seq, (id: string, idx: number) => {
                  Text((idx + 1) + '.' + this.typeName(id))
                    .fontSize(12).fontColor(DesignTokens.heroText)
                    .fontWeight(FontWeight.Bold)
                    .padding({ left: 8, right: 8, top: 5, bottom: 5 })
                    .borderRadius(DesignTokens.radiusPill).backgroundColor(this.typeColor(id))
                    .onClick(() => this.seq.splice(idx, 1))
                }, (id: string, idx: number) => idx + '-' + id)
              }.width('100%')
            }
          }
          .width('100%').padding(12).borderRadius(DesignTokens.cardRadius(false))
          .backgroundColor($r('app.color.card_bg'))
          .shadow(DesignTokens.cardShadow())

          Column({ space: 8 }) {
            Text('锚点：序列第 1 天对应的真实日期').fontSize(12).fontColor($r('app.color.text_tertiary')).width('100%')
            Row() {
              Text(DateLabel.mdw(this.anchor)).fontSize(15).fontWeight(FontWeight.Medium)
              Blank()
              Text('选择日期 ›').fontSize(13).fontColor($r('app.color.brand_pink'))
            }
            .width('100%').padding(12).borderRadius(10).backgroundColor($r('app.color.fill_weakest'))
            .onClick(() => this.pickAnchor())
          }
          .width('100%').padding(12).borderRadius(DesignTokens.cardRadius(true))
          .backgroundColor($r('app.color.card_bg'))
          .shadow(DesignTokens.cardShadow())

          Button(this.hasTemplate ? '更新模板' : '保存并展开班表')
            .width('100%').height(44).borderRadius(22).backgroundColor($r('app.color.brand_pink'))
            .fontWeight(FontWeight.Bold)
            .shadow(DesignTokens.jelly(DesignTokens.primaryDeep, DesignTokens.jellyDepth))
            .onClick(() => this.save())

          Text('保存后自动展开未来 ' + AppConst.HORIZON_DAYS + ' 天；临时换班点周历里的某一天。')
            .fontSize(11).fontColor($r('app.color.text_hint'))
        }
        .padding(12).width('100%')
      }
      .layoutWeight(1)
      // D-09：Scroll 内容短于视口时按默认对齐摆放，首屏会空出上半部；显式顶对齐。
      .align(Alignment.TopStart)
    }
    // D-38：根容器扩绘制区到状态栏/导航条之下，消掉顶底两条窗口默认底色。
    .width('100%').height('100%').backgroundColor($r('app.color.page_bg_warm'))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    .bindSheet($$this.anchorSheetVisible, this.anchorSheet(), {
      detents: [SheetSize.MEDIUM],
      dragBar: false,
      showClose: false,
      // 34vp 顶角：原型 .sheet 的圆角，比系统默认更贴糖果贴纸
      radius: { topLeft: DesignTokens.radiusSheet, topRight: DesignTokens.radiusSheet },
      blurStyle: BlurStyle.Thick
    })
  }

  /** 锚点日期 sheet：稳定 DatePicker（API 8）滚轮 + 确认/取消。 */
  @Builder
  anchorSheet() {
    Column({ space: 12 }) {
      Text('选择锚点日期').fontSize(16).fontWeight(FontWeight.Medium)
      DatePicker({
        start: ANCHOR_RANGE_START,
        end: ANCHOR_RANGE_END,
        selected: this.anchorPick
      })
        .width('100%')
        .onDateChange((d: Date) => {
          this.anchorPick = d;
        })
      Row({ space: 10 }) {
        Button('取消').layoutWeight(1).height(42).borderRadius(21)
          .backgroundColor($r('app.color.btn_neutral'))
          .fontWeight(FontWeight.Bold)
          .shadow(DesignTokens.jelly(DesignTokens.borderWeak, DesignTokens.jellyDepth))
          .onClick(() => {
            this.anchorSheetVisible = false;
          })
        Button('确定').layoutWeight(1).height(42).borderRadius(21)
          .backgroundColor($r('app.color.brand_pink'))
          .fontWeight(FontWeight.Bold)
          .shadow(DesignTokens.jelly(DesignTokens.primaryDeep, DesignTokens.jellyDepth))
          .onClick(() => this.confirmAnchor())
      }.width('100%')
    }
    .width('100%')
    .padding({ left: 20, right: 20, top: 16, bottom: 28 })
    .backgroundColor($r('app.color.page_bg_warm'))
  }
}
