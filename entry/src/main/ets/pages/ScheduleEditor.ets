import { promptAction, router } from '@kit.ArkUI';
import { HdsColorPicker, HdsColorPickerTabType } from '@kit.UIDesignKit';
import { util } from '@kit.ArkTS';
import { OWNER_ME, ShiftType, hhmmToMin, minToHHmm } from 'domain';
import { ScheduleRepo } from 'data';
import { DateLabel } from 'commons';
import { ScheduleUseCase } from 'feature';
import { ownerFromParams } from '../model/RouteParams';

const COLORS: string[] = ['#E8833A', '#3AA6E8', '#8A63D2', '#D24A7E', '#2B4C9B', '#4E9A63', '#C9A227', '#7A7A7A'];

/** 夜班判定选项：0=自动（与夜班窗口相交即恢复） 1=强制夜班（始终计入夜班恢复）。 */
const NIGHT_MODE_OPTIONS: SelectOption[] = [
  { value: '自动识别' },
  { value: '强制夜班' }
];

/** 班次类型选项：kind 持久化到 shift_type.kind（统计与展示用）。 */
interface ShiftKindOption {
  key: string;
  label: string;
}

const SHIFT_KINDS: ShiftKindOption[] = [
  { key: 'WORK', label: '工作班' },
  { key: 'DUTY', label: '值班' },
  { key: 'STUDY', label: '学习' }
];

const SHIFT_KIND_OPTIONS: SelectOption[] =
  SHIFT_KINDS.map((k: ShiftKindOption): SelectOption => ({ value: k.label }));

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
  @State allowActivity: boolean = false;
  @State kindIdx: number = 0;

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
    this.nightIdx = st.nightMode === 1 ? 1 : 0;
    this.color = st.color;
    this.allowActivity = st.allowActivity;
    this.kindIdx = this.kindIndexOf(st.kind);
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

  kindIndexOf(kind: string): number {
    for (let i = 0; i < SHIFT_KINDS.length; i++) {
      if (SHIFT_KINDS[i].key === kind) {
        return i;
      }
    }
    return 0;
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
    try {
      await ScheduleRepo.deleteShiftType(id, this.owner);
      this.editing = null;
      this.reload();
      promptAction.showToast({ message: '已删除' });
      ScheduleUseCase.onScheduleChanged().catch((e: Error) => {
        promptAction.showToast({ message: '重算失败：' + e.message });
      });
    } catch (e) {
      promptAction.showToast({ message: '删除失败：' + (e as Error).message });
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
      nightMode: this.nightIdx === 1 ? 1 : 0,
      allowActivity: this.allowActivity,
      kind: SHIFT_KINDS[this.kindIdx].key
    };
    await ScheduleRepo.upsertShiftType(st, this.owner);
    this.editing = null;
    this.reload();
    promptAction.showToast({ message: '已保存' });
    // 保存动作 → 自动重算（US6 / FR-011，ME/PARTNER 两侧一致触发）
    ScheduleUseCase.onScheduleChanged().catch((e: Error) => {
      promptAction.showToast({ message: '重算失败：' + e.message });
    });
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
            }
            .width('100%').padding(12).borderRadius(16)
            .backgroundColor($r('app.color.card_bg'))
            .shadow({ radius: 16, color: $r('app.color.shadow_soft'), offsetX: 0, offsetY: 4 })
            .onClick(() => this.edit(st))
          }
          .swipeAction({
            end: () => {
              this.deleteSwipe(st)
            },
            edgeEffect: SwipeEdgeEffect.Spring
          })
        }, (st: ShiftType) => st.id)

        if (this.editing != null) {
          ListItem() {
            Column({ space: 8 }) {
              Text('编辑：' + this.editing.name).fontSize(13).fontColor($r('app.color.brand_pink'))
              Row({ space: 8 }) {
                Text('名称').fontSize(13)
                TextInput({ text: this.name }).onChange((v: string) => this.name = v)
                  .layoutWeight(1).height(38)
              }.width('100%')
              Row({ space: 8 }) {
                Text('上班').fontSize(13)
                TextInput({ text: this.startText }).onChange((v: string) => this.startText = v)
                  .width(76).height(38)
                Text('下班').fontSize(13)
                TextInput({ text: this.endText }).onChange((v: string) => this.endText = v)
                  .width(76).height(38)
                Text('跨天自动识别').fontSize(10).fontColor($r('app.color.text_tertiary'))
              }.width('100%')
              Row({ space: 8 }) {
                Text('前通勤(分)').fontSize(13)
                TextInput({ text: this.commuteIn }).onChange((v: string) => this.commuteIn = v).width(56).height(38)
                Text('后通勤(分)').fontSize(13)
                TextInput({ text: this.commuteOut }).onChange((v: string) => this.commuteOut = v).width(56).height(38)
                Text('夜班恢复(分)').fontSize(13)
                TextInput({ text: this.recovery }).onChange((v: string) => this.recovery = v).width(56).height(38)
              }.width('100%')
              Row({ space: 8 }) {
                Text('夜班判定').fontSize(13)
                Select(NIGHT_MODE_OPTIONS)
                  .selected(this.nightIdx)
                  .value(this.nightIdx === 1 ? '强制夜班' : '自动识别')
                  .fontColor($r('app.color.text_primary'))
                  .font({ size: 13 })
                  .onSelect((idx: number, text: string) => {
                    this.nightIdx = idx;
                  })
                Text('强制夜班：无论时段，下班后始终计入恢复时长')
                  .fontSize(10).fontColor($r('app.color.text_tertiary')).layoutWeight(1)
              }.width('100%')
              Row({ space: 8 }) {
                Text('班次类型').fontSize(13)
                Select(SHIFT_KIND_OPTIONS)
                  .selected(this.kindIdx)
                  .value(SHIFT_KINDS[this.kindIdx].label)
                  .fontColor($r('app.color.text_primary'))
                  .font({ size: 13 })
                  .onSelect((idx: number, text: string) => {
                    this.kindIdx = idx;
                  })
                Text('允许班内安排活动')
                  .fontSize(12).fontColor($r('app.color.text_secondary'))
                Toggle({ type: ToggleType.Switch, isOn: this.allowActivity })
                  .onChange((on: boolean) => {
                    this.allowActivity = on;
                  })
              }.width('100%')
              if (this.allowActivity) {
                Text('值班类班次：预留能力，暂不参与空闲计算')
                  .fontSize(10).fontColor($r('app.color.text_tertiary')).width('100%')
              }
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
                  .onClick(() => this.save())
                Button(this.persisted ? '删除' : '取消')
                  .layoutWeight(1).height(44).borderRadius(22)
                  .backgroundColor($r('app.color.fill_weak')).fontColor(this.persisted ? $r('app.color.brand_pink') : $r('app.color.text_secondary'))
                  .onClick(() => this.askDelete())
              }.width('100%')
            }
            .width('100%').padding(12).borderRadius(16).backgroundColor($r('app.color.fill_weakest'))
          }
        }
      }
      .padding(12).width('100%').layoutWeight(1)
    }
    .width('100%').height('100%').backgroundColor($r('app.color.page_bg_warm'))
    .bindSheet($$this.colorSheetVisible, this.colorPickerSheet(), {
      detents: [SheetSize.LARGE],
      dragBar: false,
      showClose: true,
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
      Text('删除').fontSize(14).fontColor('#FFFFFF')
    }
    .width(72)
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor($r('app.color.danger_red'))
    .borderRadius(12)
    .onClick(() => this.askDeleteRow(st))
  }
}
