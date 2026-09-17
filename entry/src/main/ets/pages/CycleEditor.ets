import { DatePickerComponent, DatePickerComponentResult, DateMode, DisplayMode, LengthMetrics, promptAction, router } from '@kit.ArkUI';
import { OWNER_ME, CycleTemplate, ShiftType, todayEpochDay } from 'domain';
import { ScheduleRepo } from 'data';
import { AppConst, DateLabel } from 'commons';
import { ScheduleUseCase } from 'feature';
import { ownerFromParams } from '../model/RouteParams';

/** 循环模板编辑：班次序列 + 锚点日期（owner 双侧复用）。 */
@Entry
@Component
struct CycleEditor {
  @State owner: string = OWNER_ME;
  @State types: ShiftType[] = [];
  @State seq: string[] = [];
  @State anchor: number = todayEpochDay();
  @State hasTemplate: boolean = false;
  // 锚点日期 sheet（DatePickerComponent，API 26）：临时选择值，确认才落锚
  @State anchorSheetVisible: boolean = false;
  @State anchorPick: number = todayEpochDay();

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
    for (let i = 0; i < this.types.length; i++) {
      if (this.types[i].id === id) {
        return this.types[i].name;
      }
    }
    return '?';
  }

  typeColor(id: string): string {
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
    await ScheduleRepo.saveTemplate(tpl, this.owner);
    this.hasTemplate = true;
    promptAction.showToast({ message: '循环模板已保存，班表已自动展开' });
    // 保存动作 → 自动重算（US6 / FR-011，ME/PARTNER 两侧一致触发）
    ScheduleUseCase.onScheduleChanged().catch((e: Error) => {
      promptAction.showToast({ message: '重算失败：' + e.message });
    });
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
    try {
      await ScheduleRepo.deleteTemplate(this.owner);
      this.hasTemplate = false;
      this.anchor = todayEpochDay();
      promptAction.showToast({ message: '循环模板已删除' });
      ScheduleUseCase.onScheduleChanged().catch((e: Error) => {
        promptAction.showToast({ message: '重算失败：' + e.message });
      });
    } catch (e) {
      promptAction.showToast({ message: '删除失败：' + (e as Error).message });
      this.reloadTemplate();
    }
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

  /** 打开锚点日期 sheet：DatePickerComponent 滚轮选值（带触感反馈），确认后落锚。 */
  pickAnchor(): void {
    this.anchorPick = this.anchor;
    this.anchorSheetVisible = true;
  }

  /** 确认锚点：把 sheet 中的临时选择值写回。 */
  confirmAnchor(): void {
    this.anchor = this.anchorPick;
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
                  .fontSize(13).fontColor('#FFFFFF')
                  .padding({ left: 12, right: 12, top: 6, bottom: 6 })
                  .borderRadius(14).backgroundColor(st.color)
                  .onClick(() => this.seq.push(st.id))
              }, (st: ShiftType) => st.id)
            }.width('100%')

            if (this.seq.length === 0) {
              Text('序列为空').fontSize(13).fontColor($r('app.color.text_disabled'))
                .width('100%').textAlign(TextAlign.Center).padding(12)
            } else {
              Flex({ wrap: FlexWrap.Wrap, space: { main: LengthMetrics.vp(6), cross: LengthMetrics.vp(6) } }) {
                ForEach(this.seq, (id: string, idx: number) => {
                  Text((idx + 1) + '.' + this.typeName(id))
                    .fontSize(12).fontColor('#FFFFFF')
                    .padding({ left: 8, right: 8, top: 5, bottom: 5 })
                    .borderRadius(12).backgroundColor(this.typeColor(id))
                    .onClick(() => this.seq.splice(idx, 1))
                }, (id: string, idx: number) => idx + '-' + id)
              }.width('100%')
            }
          }
          .width('100%').padding(12).borderRadius(16)
          .backgroundColor($r('app.color.card_bg'))
          .shadow({ radius: 16, color: $r('app.color.shadow_soft'), offsetX: 0, offsetY: 4 })

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
          .width('100%').padding(12).borderRadius(16)
          .backgroundColor($r('app.color.card_bg'))
          .shadow({ radius: 16, color: $r('app.color.shadow_soft'), offsetX: 0, offsetY: 4 })

          Button(this.hasTemplate ? '更新模板' : '保存并展开班表')
            .width('100%').height(44).borderRadius(22).backgroundColor($r('app.color.brand_pink')).onClick(() => this.save())

          Text('说明：保存后系统按循环自动展开未来 ' + AppConst.HORIZON_DAYS
            + ' 天；临时换班请到「月历涂抹」覆盖单日。')
            .fontSize(11).fontColor($r('app.color.text_hint'))
        }
        .padding(12).width('100%')
      }
      .layoutWeight(1)
    }
    .width('100%').height('100%').backgroundColor($r('app.color.page_bg_warm'))
    .bindSheet($$this.anchorSheetVisible, this.anchorSheet(), {
      detents: [SheetSize.MEDIUM],
      dragBar: false,
      showClose: false,
      blurStyle: BlurStyle.Thick
    })
  }

  /** 锚点日期 sheet：DatePickerComponent（API 26）滚轮 + 确认/取消。 */
  @Builder
  anchorSheet() {
    Column({ space: 12 }) {
      Text('选择锚点日期').fontSize(16).fontWeight(FontWeight.Medium)
      DatePickerComponent({
        options: {
          displayMode: DisplayMode.DATE,
          dateOptions: {
            mode: DateMode.DATE,
            start: new Date(2020, 0, 1),
            end: new Date(2030, 11, 31),
            selected: new Date(this.anchorPick * 86400000),
            onChange: (r: DatePickerComponentResult) => {
              if (r.year != null && r.month != null && r.day != null) {
                this.anchorPick = Math.floor(Date.UTC(r.year, r.month - 1, r.day) / 86400000);
              }
            }
          }
        }
      })
      .width('100%')
      Row({ space: 10 }) {
        Button('取消').layoutWeight(1).height(42).borderRadius(21)
          .backgroundColor($r('app.color.btn_neutral'))
          .onClick(() => {
            this.anchorSheetVisible = false;
          })
        Button('确定').layoutWeight(1).height(42).borderRadius(21)
          .backgroundColor($r('app.color.brand_pink'))
          .onClick(() => this.confirmAnchor())
      }.width('100%')
    }
    .width('100%')
    .padding({ left: 20, right: 20, top: 16, bottom: 28 })
    .backgroundColor($r('app.color.page_bg_warm'))
  }
}
