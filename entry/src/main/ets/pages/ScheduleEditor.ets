import { LengthMetrics, router } from '@kit.ArkUI';
import { HdsColorPicker, HdsColorPickerTabType, HdsColorPickerOptions } from '@kit.UIDesignKit';
import { util } from '@kit.ArkTS';
import { OWNER_ME, ShiftType, ShiftSegment, shiftSegments, shiftError, minToHHmm } from 'domain';
import { ScheduleRepo } from 'data';
import { ScheduleCommandService, ScheduleUseCase, NIGHT_MODE_LABELS, nightModeHint, nightModeIndex, nightModeOf } from 'feature';
import { ownerFromParams } from '../model/RouteParams';
import { TimeSegmentsEditor } from '../component/TimeSegmentsEditor';
import { NoticeBar, NoticeTone } from '../component/NoticeBar';
import { DesignTokens } from '../theme/DesignTokens';
import { toastCommand } from '../util/CommandToast';
import { appToast } from '../util/AppToast';
import { askConfirm } from '../util/AppConfirm';
import { LatestLanding } from '../util/LatestLanding';

/**
 * 班次调色板：02「Q糖」的糖果八色。存库的是这里的字面值，不是资源键，所以取值要一次定对——
 * 月历格子与循环预览都直接把这块色当底色用。
 *
 * 旧注释写的是"八色的白字对比度全部核过 ≥2.99:1，换色时按同一口径挑"，那条**前提**已经不成立：
 * 同一页有 `HdsColorPicker`（GRID/SPECTRUM/SLIDERS，`onColorSelected` 交出任意串），
 * 用户挑得到的颜色远不止这八色。现在色块上的前景不写死，由 `DesignTokens.foregroundOn` 按底色算，
 * 所以换色不再需要手工核对比度。八色在新判据下仍全部落在暖白（2.99–4.76:1，`SwatchInkTest` 逐色钉住）。
 */
const COLORS: string[] = ['#EF6F42', '#4E97DB', '#9A6BDC', '#F0568C', '#5B6ACF', '#3A9E6E', '#C08A2A', '#8E8397'];
const COLOR_PICKER_OPTIONS: HdsColorPickerOptions = {
  circleRadius: 13,
  tabs: [HdsColorPickerTabType.GRID, HdsColorPickerTabType.SPECTRUM, HdsColorPickerTabType.SLIDERS]
};

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
  /** 读失败要说成"没读到"：留一片空白会被读成"我的班次类型都没了"（同 D-22 的口径）。 */
  @State failed: boolean = false;
  @State editing: ShiftType | null = null;
  /** 编辑中的是否为已落库班次（false = 新增未保存，删除按钮退化为取消）。 */
  @State persisted: boolean = false;
  @State name: string = '';
  @State segments: ShiftSegment[] = [{ startMin: 540, endMin: 1080, crossDay: false }];
  @State commuteIn: string = '30';
  @State commuteOut: string = '30';
  @State recovery: string = '0';
  @State nightIdx: number = 0;
  @State color: string = COLORS[0];
  @State private editorVisible: boolean = false;
  @State private pickerInitialColor: string = COLORS[0];
  @State private submitting: boolean = false;
  /**
   * 并发读数闸门（D-51）：删除/保存的本地收尾各读一次列表，连点两次删除时先起的那读晚落地，
   * 调色板会把已经删掉的那个班次画回来（D-40 之后键吃进了显示字段，所以它真会重画）。
   */
  private landing: LatestLanding = new LatestLanding();

  aboutToAppear(): void {
    this.owner = ownerFromParams(router.getParams());
    this.reload();
  }

  reload(): void {
    const token = this.landing.begin();
    ScheduleUseCase.ensureSeeded(this.owner).then(() => {
      return ScheduleRepo.listShiftTypes(this.owner);
    }).then((list: ShiftType[]) => {
      if (!this.landing.isCurrent(token)) {
        return;
      }
      this.types = list;
      this.failed = false;
    }).catch(() => {
      if (!this.landing.isCurrent(token)) {
        return;
      }
      this.types = [];
      this.failed = true;
    });
  }

  edit(st: ShiftType): void {
    if (this.submitting) {
      return;
    }
    this.editing = st;
    this.persisted = this.isPersisted(st.id);
    this.name = st.name;
    this.segments = shiftSegments(st).map((s: ShiftSegment): ShiftSegment => {
      return { startMin: s.startMin, endMin: s.endMin, crossDay: s.crossDay };
    });
    this.commuteIn = '' + st.commuteInMin;
    this.commuteOut = '' + st.commuteOutMin;
    this.recovery = '' + st.recoveryMin;
    this.nightIdx = nightModeIndex(st.nightMode);
    this.color = st.color;
    this.pickerInitialColor = st.color;
    this.editorVisible = true;
  }

  private closeEditor(): void {
    if (this.submitting) {
      return;
    }
    this.editorVisible = false;
    this.editing = null;
  }

  /**
   * 行 key 带上屏内显示的每一个字段（D-40，与 D-30 的 PlansView.cardKey 同一族）。
   * 只按 id 做 key 时，保存后 reload 换掉的是数组、不是节点，这一行仍念着改值前的旧数字；
   * 编辑器在独立 sheet 中，重建列表行不会重置编辑草稿。
   */
  rowKey(st: ShiftType): string {
    return st.id + '-' + st.name + '-' + st.color + '-' + st.startMin + '-' + st.endMin
      + '-' + (st.crossDay ? 1 : 0) + '-' + st.commuteInMin + '/' + st.commuteOutMin
      + '-' + st.recoveryMin + '-' + JSON.stringify(st.segments || []);
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
    if (this.submitting) {
      return;
    }
    if (this.editing == null) {
      return;
    }
    if (!this.persisted) {
      this.closeEditor();
      return;
    }
    const target = this.editing;
    askConfirm(this.getUIContext(), {
      message: '删除班次「' + target.name + '」？已保存的周班表不会改变；旧循环中的引用会失效。',
      confirmText: '删除',
      onConfirm: () => {
        this.doDelete(target.id);
      }
    });
  }

  /** 删除班次二次确认（列表行级入口，与编辑表单内删除并行）。 */
  askDeleteRow(st: ShiftType): void {
    askConfirm(this.getUIContext(), {
      message: '删除班次「' + st.name + '」？已保存的周班表不会改变；旧循环中的引用会失效。',
      confirmText: '删除',
      onConfirm: () => {
        this.doDelete(st.id);
      }
    });
  }

  async doDelete(id: string): Promise<void> {
    if (this.submitting) {
      return;
    }
    this.submitting = true;
    const r = await ScheduleCommandService.removeShiftType(id, this.owner);
    this.submitting = false;
    toastCommand(r, '已删除');
    if (r.changed) {
      this.closeEditor();
      this.reload();
    }
  }

  async save(): Promise<void> {
    if (this.submitting) {
      return;
    }
    if (this.segments.length === 0) { appToast('请添加工作时段'); return; }
    const st: ShiftType = {
      id: this.editing != null ? this.editing.id : util.generateRandomUUID(),
      name: this.name, color: this.color,
      startMin: this.segments[0].startMin, endMin: this.segments[0].endMin,
      crossDay: this.segments[0].crossDay, segments: this.segments,
      commuteInMin: this.toInt(this.commuteIn, 0),
      commuteOutMin: this.toInt(this.commuteOut, 0),
      recoveryMin: this.toInt(this.recovery, 0),
      nightMode: nightModeOf(this.nightIdx),
      allowActivity: false,
      kind: 'WORK'
    };
    this.submitting = true;
    const invalid = shiftError(st);
    if (invalid !== '') { this.submitting = false; appToast(invalid); return; }
    const r = await ScheduleCommandService.saveShiftType(st, this.owner);
    this.submitting = false;
    if (r.changed) {
      this.closeEditor();
      this.reload();
    }
    toastCommand(r, '已保存');
  }

  private timesLabel(st: ShiftType): string {
    return shiftSegments(st).map((s: ShiftSegment): string =>
      minToHHmm(s.startMin) + '–' + minToHHmm(s.endMin) + (s.crossDay || s.endMin <= s.startMin ? ' 次日' : '')).join(' · ');
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
        Text(this.owner === OWNER_ME ? '常用班次' : 'TA 的常用班次').fontSize(17).fontWeight(FontWeight.Bold)
        Blank()
        Text('+ 新增').fontSize(15).fontColor($r('app.color.brand_pink')).onClick(() => this.newOne())
      }
      .width('100%').padding(12)

      if (this.failed) {
        // 空列表在这里没有任何说法，读失败与"一个班次类型都没有"看上去一模一样。
        NoticeBar({
          tone: NoticeTone.ERROR,
          title: '班次类型没读到',
          body: '不是还没有班次类型，是这次没读出来。',
          actionLabel: '重试',
          onAction: () => {
            this.reload();
          }
        })
      }

      List({ space: 10 }) {
        ForEach(this.types, (st: ShiftType) => {
          ListItem() {
            Row({ space: 10 }) {
              Circle().width(14).height(14).fill(st.color)
              Column({ space: 2 }) {
                Text(st.name).fontSize(15).fontWeight(FontWeight.Medium)
                Text(this.timesLabel(st))
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
            .clickEffect(DesignTokens.tapButton())
            .onClick(() => this.edit(st))
          }
          .swipeAction({
            end: () => {
              this.deleteSwipe(st)
            },
            edgeEffect: SwipeEdgeEffect.Spring
          })
        }, (st: ShiftType) => this.rowKey(st))


        ListItem() {
          Text('休息间隔不占用；修改班次不影响已排日期。')
            .fontSize(11).fontColor($r('app.color.text_hint')).width('100%').padding({ top: 4 })
        }
      }
      .padding(12).width('100%').layoutWeight(1)
    }
    // D-38：根容器停在安全区里侧，状态栏与导航条那两条露出窗口默认底色；扩绘制区消掉白条。
    .width('100%').height('100%').linearGradient(DesignTokens.pageGradient())
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    .bindSheet($$this.editorVisible, this.editorSheet(), {
      detents: ['72%'],
      dragBar: false,
      showClose: false,
      // 34vp 顶角：原型 .sheet 的圆角，比系统默认更贴糖果贴纸
      radius: { topLeft: DesignTokens.radiusSheet, topRight: DesignTokens.radiusSheet },
      backgroundColor: Color.Transparent,
      blurStyle: BlurStyle.NONE,
      maskColor: DesignTokens.scrim,
      onWillDismiss: (action: DismissSheetAction) => {
        if (!this.submitting) {
          action.dismiss();
          this.closeEditor();
        }
      }
    })
  }

  @Builder
  shiftForm() {
    Column({ space: 12 }) {
      Row({ space: 8 }) {
        Text('名称').fontSize(DesignTokens.fontBody).fontColor(DesignTokens.textSecondary)
        TextInput({ text: this.name }).onChange((v: string) => this.name = v)
          .layoutWeight(1).constraintSize({ minHeight: 44 })
          .borderRadius(DesignTokens.radiusInput)
          .border({ width: 1.5, color: DesignTokens.primaryBorder })
          .backgroundColor(DesignTokens.card).enabled(!this.submitting)
          .accessibilityText('班次名称')
      }.width('100%')
      TimeSegmentsEditor({ segments: this.segments, editable: !this.submitting,
        onChange: (segments: ShiftSegment[]) => { this.segments = segments; } })
      Flex({ wrap: FlexWrap.Wrap, space: { main: LengthMetrics.vp(8), cross: LengthMetrics.vp(8) } }) {
        Row({ space: 8 }) {
          Text('上班通勤\n（分钟）').fontSize(DesignTokens.fontCaption).fontColor(DesignTokens.textSecondary)
          TextInput({ text: this.commuteIn }).type(InputType.Number)
            .onChange((v: string) => this.commuteIn = v)
            .layoutWeight(1).constraintSize({ minWidth: 56, minHeight: 44 })
            .borderRadius(DesignTokens.radiusInput).backgroundColor(DesignTokens.fillWeakest)
            .enabled(!this.submitting).accessibilityText('上班前通勤分钟数')
        }.layoutWeight(1).constraintSize({ minWidth: 136 })
        Row({ space: 8 }) {
          Text('下班通勤\n（分钟）').fontSize(DesignTokens.fontCaption).fontColor(DesignTokens.textSecondary)
          TextInput({ text: this.commuteOut }).type(InputType.Number)
            .onChange((v: string) => this.commuteOut = v)
            .layoutWeight(1).constraintSize({ minWidth: 56, minHeight: 44 })
            .borderRadius(DesignTokens.radiusInput).backgroundColor(DesignTokens.fillWeakest)
            .enabled(!this.submitting).accessibilityText('下班后通勤分钟数')
        }.layoutWeight(1).constraintSize({ minWidth: 136 })
      }.width('100%')
      Row({ space: 8 }) {
        Text('夜班恢复（分钟）').fontSize(DesignTokens.fontCaption).fontColor(DesignTokens.textSecondary)
        TextInput({ text: this.recovery }).type(InputType.Number)
          .onChange((v: string) => this.recovery = v).layoutWeight(1)
          .constraintSize({ minWidth: 56, minHeight: 44 })
          .borderRadius(DesignTokens.radiusInput).backgroundColor(DesignTokens.fillWeakest)
          .enabled(!this.submitting).accessibilityText('夜班恢复分钟数，零表示不额外计算')
      }.width('100%')
      Row({ space: 8 }) {
        Text('夜班判定').fontSize(DesignTokens.fontCaption).fontColor(DesignTokens.textSecondary)
        Select(NIGHT_MODE_OPTIONS).selected(this.nightIdx).value(NIGHT_MODE_LABELS[this.nightIdx])
          .fontColor(DesignTokens.textPrimary).layoutWeight(1).enabled(!this.submitting)
          .accessibilityText('夜班判定方式')
          .onSelect((idx: number) => { this.nightIdx = idx; })
      }.width('100%')
      Text(nightModeHint(this.nightIdx)).fontSize(DesignTokens.fontCaption).fontColor(DesignTokens.textSecondary)

      Text('班次颜色').fontSize(DesignTokens.fontCaption).fontColor(DesignTokens.textSecondary)
      Flex({ wrap: FlexWrap.Wrap, space: { main: LengthMetrics.vp(4), cross: LengthMetrics.vp(4) } }) {
        ForEach(COLORS, (c: string) => {
          Row() {
            Circle().width(26).height(26).fill(c)
              .stroke(c === this.color ? DesignTokens.textPrimary : c).strokeWidth(2)
          }.width(44).height(44).justifyContent(FlexAlign.Center)
            .borderRadius(22).focusable(true)
            .accessibilityText('班次颜色 ' + c).accessibilityChecked(c === this.color)
            .clickEffect(DesignTokens.tapChip())
            .onClick(() => {
              if (!this.submitting) {
                this.color = c;
                this.pickerInitialColor = c;
              }
            })
        }, (c: string) => c)
        Stack({ alignContent: Alignment.Center }) {
          HdsColorPicker({
            initialColor: this.pickerInitialColor,
            onColorSelected: (c: string) => {
              if (this.editorVisible && !this.submitting) {
                this.color = c;
                this.pickerInitialColor = c;
              }
            },
            initialFavoriteColors: COLORS,
            options: COLOR_PICKER_OPTIONS
          }).width(26).height(26).enabled(!this.submitting)
            .accessibilityText('选择自定义班次颜色')
        }.width(44).height(44)
      }.width('100%')
      Row({ space: 8 }) {
        Circle().width(18).height(18).fill(this.color)
        Text('当前颜色 ' + this.color).fontSize(DesignTokens.fontCaption).fontColor(DesignTokens.textSecondary)
      }
      if (this.persisted) {
        Button('删除这个班次').width('100%').height(44)
          .backgroundColor(DesignTokens.fillWeak).fontColor(DesignTokens.danger)
          .enabled(!this.submitting).onClick(() => this.askDelete())
      }
    }.width('100%').alignItems(HorizontalAlign.Start).padding({ bottom: 12 })
  }

  @Builder
  editorSheet() {
    Column({ space: 12 }) {
      Text(this.persisted ? '编辑班次' : '新增班次')
        .fontSize(DesignTokens.fontTitle).fontWeight(FontWeight.Bold).fontColor(DesignTokens.textPrimary)
        .width('100%')
      Scroll() {
        this.shiftForm()
      }.width('100%').layoutWeight(1).align(Alignment.TopStart).scrollBar(BarState.Off)
      Row({ space: 10 }) {
        Button('取消').layoutWeight(1).height(44).backgroundColor(DesignTokens.fillWeak)
          .fontColor(DesignTokens.textPrimary).enabled(!this.submitting).onClick(() => this.closeEditor())
        Button(this.submitting ? '保存中…' : '保存班次').layoutWeight(1).height(44)
          .backgroundColor(DesignTokens.primary).fontColor(DesignTokens.heroText)
          .enabled(!this.submitting).onClick(() => this.save())
      }.width('100%')
    }.width('100%').height('100%').padding(20).backgroundColor(DesignTokens.card)
      .borderRadius({ topLeft: DesignTokens.radiusSheet, topRight: DesignTokens.radiusSheet }).clip(true)
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
    .clickEffect(DesignTokens.tapButton())
    .onClick(() => this.askDeleteRow(st))
  }
}
