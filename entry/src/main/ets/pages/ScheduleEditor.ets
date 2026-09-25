import { promptAction, router } from '@kit.ArkUI';
import { HdsColorPicker, HdsColorPickerTabType } from '@kit.UIDesignKit';
import { util } from '@kit.ArkTS';
import { OWNER_ME, ShiftType, hhmmToMin, minToHHmm } from 'domain';
import { ScheduleRepo } from 'data';
import { DateLabel } from 'commons';
import { ScheduleCommandService, ScheduleUseCase, NIGHT_MODE_LABELS, nightModeHint, nightModeIndex, nightModeOf } from 'feature';
import { ownerFromParams } from '../model/RouteParams';
import { DesignTokens } from '../theme/DesignTokens';
import { toastCommand } from '../util/CommandToast';

const COLORS: string[] = ['#E8833A', '#3AA6E8', '#8A63D2', '#D24A7E', '#2B4C9B', '#4E9A63', '#C9A227', '#7A7A7A'];

/** 夜班判定三档（D-33）：文字与档位来自 feature/model/RhythmRules，顺序即存库值。 */
const NIGHT_MODE_OPTIONS: SelectOption[] = NIGHT_MODE_LABELS.map((label: string): SelectOption => {
  const opt: SelectOption = { value: label };
  return opt;
});

/** 班次类型管理：列表 + 编辑表单（owner 双侧复用，班次类型按 owner 隔离）。 */
@Entry
@Component
struct ScheduleEditor {
  @State owner: string = OWNER_ME;
  @State types: ShiftType[] = [];
  @State editing: ShiftType | null = null;
  /** 编辑中的是否为已落库班次（false = 新增未保存，删除按钮退化为取消）。 */
  @State persisted: boolean = false;
  @State name: string = '';
  @State startText: string = '09:00';
  @State endText: string = '18:00';
  @State commuteIn: string = '30';
  @State commuteOut: string = '30';
  @State recovery: string = '0';
  @State nightIdx: number = 0;
  @State color: string = COLORS[0];
  // 自定义取色 sheet（HdsColorPicker，API 26）
  @State colorSheetVisible: boolean = false;

  aboutToAppear(): void {
    this.owner = ownerFromParams(router.getParams());
    this.reload();
  }

  reload(): void {
    ScheduleUseCase.ensureSeeded(this.owner).then(() => {
      return ScheduleRepo.listShiftTypes(this.owner);
    }).then((list: ShiftType[]) => {
      this.types = list;
    }).catch(() => {
      this.types = [];
    });
  }

  edit(st: ShiftType): void {
    this.editing = st;
    this.persisted = this.isPersisted(st.id);
    this.name = st.name;
    this.startText = minToHHmm(st.startMin);
    this.endText = minToHHmm(st.endMin);
    this.commuteIn = '' + st.commuteInMin;
    this.commuteOut = '' + st.commuteOutMin;
    this.recovery = '' + st.recoveryMin;
    this.nightIdx = nightModeIndex(st.nightMode);
    this.color = st.color;
  }

  /**
   * 行 key 带上屏内显示的每一个字段（D-40，与 D-30 的 PlansView.cardKey 同一族）。
   * 只按 id 做 key 时，保存后 reload 换掉的是数组、不是节点，这一行仍念着改值前的旧数字；
   * 行内编辑器是 ForEach 之外的独立 ListItem，重建列表行不会碰到它。
   */
  rowKey(st: ShiftType): string {
    return st.id + '-' + st.name + '-' + st.color + '-' + st.startMin + '-' + st.endMin
      + '-' + (st.crossDay ? 1 : 0) + '-' + st.commuteInMin + '/' + st.commuteOutMin
      + '-' + st.recoveryMin;
  }

  /** id 是否已存在于列表（区分"编辑已保存班次"与"新增未保存"）。 */
  isPersisted(id: string): boolean {
    for (let i = 0; i < this.types.length; i++) {
      if (this.types[i].id === id) {
        return true;
      }
    }
    return false;
  }

  newOne(): void {
    const st: ShiftType = {
      id: util.generateRandomUUID(), name: '新班次', color: COLORS[0],
      startMin: 540, endMin: 1080, crossDay: false,
      commuteInMin: 30, commuteOutMin: 30, recoveryMin: 0,
      nightMode: 0, allowActivity: false, kind: 'WORK'
    };
    this.edit(st);
  }

  /** 删除当前编辑的班次（已落库）；新增未保存的"删除"退化为取消编辑。 */
  askDelete(): void {
    if (this.editing == null) {
      return;
    }
    if (!this.persisted) {
      this.editing = null;
      return;
    }
    const target = this.editing;
    this.getUIContext().showAlertDialog({
      message: '删除班次「' + target.name + '」？循环模板中引用该班次的格子会显示为空。',
      primaryButton: {
        value: '取消',
        action: () => {
        }
      },
      secondaryButton: {
        value: '删除',
        fontColor: $r('app.color.brand_pink'),
        action: () => {
          this.doDelete(target.id);
        }
      }
    });
  }

  /** 删除班次二次确认（列表行级入口，与编辑表单内删除并行）。 */
  askDeleteRow(st: ShiftType): void {
    this.getUIContext().showAlertDialog({
      message: '删除班次「' + st.name + '」？循环模板中引用该班次的格子会显示为空。',
      primaryButton: {
        value: '取消',
        action: () => {
        }
      },
      secondaryButton: {
        value: '删除',
        fontColor: $r('app.color.brand_pink'),
        action: () => {
          this.doDelete(st.id);
        }
      }
    });
  }

  async doDelete(id: string): Promise<void> {
    const r = await ScheduleCommandService.removeShiftType(id, this.owner);
    toastCommand(r, '已删除');
    if (r.changed) {
      this.editing = null;
      this.reload();
    }
  }

  async save(): Promise<void> {
    const start = hhmmToMin(this.startText);
    const end = hhmmToMin(this.endText);
    if (this.name === '' || start < 0 || end < 0) {
      promptAction.showToast({ message: '请检查名称与时间格式（HH:MM）' });
      return;
    }
    const st: ShiftType = {
      id: this.editing != null ? this.editing.id : util.generateRandomUUID(),
      name: this.name, color: this.color,
      startMin: start, endMin: end,
      crossDay: end <= start,
      commuteInMin: this.toInt(this.commuteIn, 0),
      commuteOutMin: this.toInt(this.commuteOut, 0),
      recoveryMin: this.toInt(this.recovery, 0),
      nightMode: nightModeOf(this.nightIdx),
      allowActivity: false,
      kind: 'WORK'
    };
    const r = await ScheduleCommandService.saveShiftType(st, this.owner);
    if (r.changed) {
      this.editing = null;
      this.reload();
    }
    toastCommand(r, '已保存');
  }

  toInt(text: string, dft: number): number {
    const v = Number.parseInt(text, 10);
    return Number.isNaN(v) || v < 0 ? dft : v;
  }

  build() {
    Column() {
      Row() {
        Row({ space: 2 }) {
          SymbolGlyph($r('sys.symbol.chevron_left')).fontSize(16).fontColor([$r('app.color.brand_pink')])
          Text('返回').fontSize(15).fontColor($r('app.color.brand_pink'))
        }.onClick(() => router.back())
        Blank()
        Text(this.owner === OWNER_ME ? '班次类型' : 'TA 的班次类型').fontSize(17).fontWeight(FontWeight.Bold)
        Blank()
        Text('+ 新增').fontSize(15).fontColor($r('app.color.brand_pink')).onClick(() => this.newOne())
      }
      .width('100%').padding(12)

      List({ space: 10 }) {
        ForEach(this.types, (st: ShiftType) => {
          ListItem() {
            Row({ space: 10 }) {
              Circle().width(14).height(14).fill(st.color)
              Column({ space: 2 }) {
                Text(st.name).fontSize(15).fontWeight(FontWeight.Medium)
                Text(minToHHmm(st.startMin) + '–' + minToHHmm(st.endMin)
                  + (st.crossDay ? '（次日）' : '')
                  + ' · 通勤 ' + st.commuteInMin + '/' + st.commuteOutMin
                  + '分 · 恢复 ' + st.recoveryMin + '分')
                  .fontSize(11).fontColor($r('app.color.text_tertiary'))
              }.alignItems(HorizontalAlign.Start)
              Blank()
              // D-12：行内可见「删除」。左滑那条继续保留（与 CourseImport 并存），这里只补可发现性。
              Text('删除').fontSize(13).fontColor($r('app.color.danger_red'))
                .accessibilityText('删除班次：' + st.name)
                .onClick(() => this.askDeleteRow(st))
            }
            .width('100%').padding(12).borderRadius(DesignTokens.cardRadius(false))
            .backgroundColor($r('app.color.card_bg'))
            .shadow(DesignTokens.cardShadow())
            .onClick(() => this.edit(st))
          }
          .swipeAction({
            end: () => {
              this.deleteSwipe(st)
            },
            edgeEffect: SwipeEdgeEffect.Spring
          })
        }, (st: ShiftType) => this.rowKey(st))

        if (this.editing != null) {
          ListItem() {
            Column({ space: 8 }) {
              Text('编辑：' + this.editing.name).fontSize(13).fontColor($r('app.color.brand_pink'))
              Row({ space: 8 }) {
                Text('名称').fontSize(13)
                TextInput({ text: this.name }).onChange((v: string) => this.name = v)
                  .layoutWeight(1).height(42)
                  .borderRadius(DesignTokens.radiusInput)
                  .border({ width: 1.5, color: DesignTokens.primaryBorder })
                  .backgroundColor(DesignTokens.card)
              }.width('100%')
              Row({ space: 8 }) {
                Text('上班').fontSize(13)
                TextInput({ text: this.startText }).onChange((v: string) => this.startText = v)
                  .width(76).height(42)
                  .borderRadius(DesignTokens.radiusInput)
                  .border({ width: 1.5, color: DesignTokens.primaryBorder })
                  .backgroundColor(DesignTokens.card)
                Text('下班').fontSize(13)
                TextInput({ text: this.endText }).onChange((v: string) => this.endText = v)
                  .width(76).height(42)
                  .borderRadius(DesignTokens.radiusInput)
                  .border({ width: 1.5, color: DesignTokens.primaryBorder })
                  .backgroundColor(DesignTokens.card)
                Text('跨天自动识别').fontSize(10).fontColor($r('app.color.text_tertiary'))
              }.width('100%')
              Row({ space: 8 }) {
                Text('前通勤(分)').fontSize(13)
                TextInput({ text: this.commuteIn }).onChange((v: string) => this.commuteIn = v).width(56).height(42)
                  .borderRadius(DesignTokens.radiusInput)
                  .border({ width: 1.5, color: DesignTokens.primaryBorder })
                  .backgroundColor(DesignTokens.card)
                Text('后通勤(分)').fontSize(13)
                TextInput({ text: this.commuteOut }).onChange((v: string) => this.commuteOut = v).width(56).height(42)
                  .borderRadius(DesignTokens.radiusInput)
                  .border({ width: 1.5, color: DesignTokens.primaryBorder })
                  .backgroundColor(DesignTokens.card)
              }.width('100%')
              // D-35：三对「标签＋输入框」同排时 Row 不折行，第三枚被推到屏外只剩 5 px。
              // 恢复值是 recovery 分钟数的唯一入口，必须单独占一排才够得着。
              Row({ space: 8 }) {
                Text('夜班恢复(分)').fontSize(13)
                TextInput({ text: this.recovery }).onChange((v: string) => this.recovery = v).width(56).height(42)
                  .borderRadius(DesignTokens.radiusInput)
                  .border({ width: 1.5, color: DesignTokens.primaryBorder })
                  .backgroundColor(DesignTokens.card)
              }.width('100%')
              Row({ space: 8 }) {
                Text('夜班判定').fontSize(13)
                Select(NIGHT_MODE_OPTIONS)
                  .selected(this.nightIdx)
                  .value(NIGHT_MODE_LABELS[this.nightIdx])
                  .fontColor($r('app.color.text_primary'))
                  .font({ size: 13 })
                  .onSelect((idx: number, text: string) => {
                    this.nightIdx = idx;
                  })
                Text(nightModeHint(this.nightIdx))
                  .fontSize(10).fontColor($r('app.color.text_tertiary')).layoutWeight(1)
              }.width('100%')
              Row({ space: 10 }) {
                ForEach(COLORS, (c: string) => {
                  Circle().width(26).height(26).fill(c)
                    .stroke(c === this.color ? $r('app.color.text_primary') : c).strokeWidth(2)
                    .onClick(() => this.color = c)
                }, (c: string) => c)
                // 自定义颜色：打开 HdsColorPicker（网格 / 光谱 / 滑块）
                Circle().width(26).height(26)
                  .linearGradient({
                    angle: 135,
                    colors: [['#D24A7E', 0], ['#3AA6E8', 0.5], ['#4E9A63', 1]]
                  })
                  .stroke($r('app.color.text_disabled')).strokeWidth(2)
                  .onClick(() => {
                    this.colorSheetVisible = true;
                  })
              }.width('100%')
              Row({ space: 10 }) {
                Button('保存班次').layoutWeight(1).height(44).borderRadius(22)
                  .backgroundColor($r('app.color.brand_pink'))
                  .fontWeight(FontWeight.Bold)
                  .shadow(DesignTokens.jelly(DesignTokens.primaryDeep, DesignTokens.jellyDepth))
                  .onClick(() => this.save())
                Button(this.persisted ? '删除' : '取消')
                  .layoutWeight(1).height(44).borderRadius(22)
                  .backgroundColor($r('app.color.fill_weak')).fontColor(this.persisted ? $r('app.color.brand_pink') : $r('app.color.text_secondary'))
                  .fontWeight(FontWeight.Bold)
                  .shadow(DesignTokens.jelly(DesignTokens.borderWeak, DesignTokens.jellyDepth))
                  .onClick(() => this.askDelete())
              }.width('100%')
            }
            .width('100%').padding(12).borderRadius(DesignTokens.cardRadius(false))
            .backgroundColor($r('app.color.fill_weakest'))
            .shadow(DesignTokens.cardShadow())
          }
        }

        // D-12 页脚。原型那句「跨天自动识别为夜班」与代码不符（判定看的是夜班窗口相交，见
        // AvailabilityBuilder.isNightShift），所以这里念规则本身而不是抄文案。
        ListItem() {
          Column({ space: 4 }) {
            Text('夜班：自动档要班次时段与夜班窗口相交才算，跨天不等于夜班；「强制夜班」不看窗口、始终计入；「不触发夜班恢复」即使相交也不生成恢复块。')
              .fontSize(11).fontColor($r('app.color.text_hint'))
            Text('恢复块另需「夜班恢复(分)」大于 0；班次删空后，内置六个班次会重新种回。')
              .fontSize(11).fontColor($r('app.color.text_hint'))
          }
          .alignItems(HorizontalAlign.Start).width('100%').padding({ top: 4 })
        }
      }
      .padding(12).width('100%').layoutWeight(1)
    }
    // D-38：根容器停在安全区里侧，状态栏与导航条那两条露出窗口默认底色；扩绘制区消掉白条。
    .width('100%').height('100%').backgroundColor($r('app.color.page_bg_warm'))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    .bindSheet($$this.colorSheetVisible, this.colorPickerSheet(), {
      detents: [SheetSize.LARGE],
      dragBar: false,
      showClose: true,
      // 34vp 顶角：原型 .sheet 的圆角，比系统默认更贴糖果贴纸
      radius: { topLeft: DesignTokens.radiusSheet, topRight: DesignTokens.radiusSheet },
      blurStyle: BlurStyle.Thick
    })
  }

  /** 自定义取色 sheet：HdsColorPicker 三模式（网格 / 光谱 / 滑块），选色即回填并收回。 */
  @Builder
  colorPickerSheet() {
    Column() {
      HdsColorPicker({
        initialColor: this.color,
        onColorSelected: (c: string) => {
          this.color = c;
          this.colorSheetVisible = false;
        },
        initialFavoriteColors: COLORS,
        options: {
          tabs: [HdsColorPickerTabType.GRID, HdsColorPickerTabType.SPECTRUM, HdsColorPickerTabType.SLIDERS]
        }
      })
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_bg_warm'))
  }

  /** 左滑露出的"删除"按钮（红色，点击走二次确认）。 */
  @Builder
  deleteSwipe(st: ShiftType) {
    Row() {
      Text('删除').fontSize(14).fontColor(DesignTokens.heroText)
    }
    .width(72)
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor($r('app.color.danger_red'))
    .borderRadius(12)
    .onClick(() => this.askDeleteRow(st))
  }
}
