import { promptAction, router } from '@kit.ArkUI';
import {
  OWNER_ME, CycleTemplate, ScheduleOverride, ShiftType, epochDayOf, expandCycle, todayEpochDay
} from 'domain';
import { ScheduleRepo } from 'data';
import { Logger } from 'commons';
import { ScheduleUseCase } from 'feature';
import { ownerFromParams } from '../model/RouteParams';

/** 日历格数据（@Observed：涂抹时原地修改属性，子组件 @ObjectLink 精准刷新，不重建组件、不打断拖动手势）。 */
@Observed
class DayCell {
  day: number;
  epochDay: number;
  /** 循环模板展开出的班次 id；'' 表示循环层为休。 */
  baseId: string;
  /** 手动覆盖班次 id；null 表示无覆盖。 */
  overId: string | null;
  color: string;
  label: string;

  constructor(day: number, epochDay: number, baseId: string, overId: string | null,
    color: string, label: string) {
    this.day = day;
    this.epochDay = epochDay;
    this.baseId = baseId;
    this.overId = overId;
    this.color = color;
    this.label = label;
  }
}

const ROW_H: number = 54;
const WD_HEAD: string[] = ['一', '二', '三', '四', '五', '六', '日'];
const REST_KEY = '__rest__';
/** 拖动连刷后的批量持久化 + 重算合并窗口（毫秒）。 */
const PERSIST_DEBOUNCE_MS: number = 400;

/**
 * 月历涂抹：拖动/点按标记班次，长按清除，覆盖层与循环模板并存（owner 双侧复用）。
 * 性能设计：涂抹时仅原地更新内存单元格（乐观 UI），覆盖写入按 400ms 防抖批量落库，
 * 避免"逐格全量重读月历 + 逐格全量重算"。
 */
@Entry
@Component
struct PaintMonth {
  @State owner: string = OWNER_ME;
  @State year: number = 2026;
  @State month: number = 9;
  @State cells: DayCell[] = [];
  @State leadingBlanks: number = 0;
  @State gridW: number = 320;
  @State brushId: string = '';
  @State types: ShiftType[] = [];
  @State template: CycleTemplate | null = null;
  private overMap: Map<number, string | null> = new Map();
  /** 当月首日 epochDay（epochDay → cells 下标换算用）。 */
  private monthStart: number = 0;
  private lastPainted: number = -1;
  // 待落库的覆盖变更（防抖批量写入）
  private dirtyUpsert: Map<number, string | null> = new Map();
  private dirtyDelete: Set<number> = new Set();
  private persistTimer: number = -1;

  aboutToAppear(): void {
    this.owner = ownerFromParams(router.getParams());
    const now = new Date();
    this.year = now.getFullYear();
    this.month = now.getMonth() + 1;
    this.loadAll();
  }

  /** 离开页面时立即冲刷未落库的涂抹（防抖窗口内退出不丢数据）。 */
  aboutToDisappear(): void {
    if (this.persistTimer >= 0) {
      clearTimeout(this.persistTimer);
      this.persistTimer = -1;
    }
    this.flushPersist();
  }

  async loadAll(): Promise<void> {
    await ScheduleUseCase.ensureSeeded(this.owner);
    // 画笔列表按 owner 隔离：读对应一方的班次类型
    this.types = await ScheduleRepo.listShiftTypes(this.owner);
    this.template = await ScheduleRepo.getTemplate(this.owner);
    await this.loadMonth();
  }

  async loadMonth(): Promise<void> {
    const start = epochDayOf(this.year, this.month, 1);
    this.monthStart = start;
    const dim = new Date(this.year, this.month, 0).getDate();
    const firstWd = new Date(this.year, this.month - 1, 1).getDay();
    this.leadingBlanks = (firstWd + 6) % 7;
    const ovs = await ScheduleRepo.listOverrides(start, start + dim - 1, this.owner);
    this.overMap = new Map();
    for (let i = 0; i < ovs.length; i++) {
      this.overMap.set(ovs[i].epochDay, ovs[i].shiftTypeId);
    }
    const insts = this.template != null ? expandCycle(this.template, [], start, dim) : [];
    const baseMap = new Map<number, string>();
    for (let i = 0; i < insts.length; i++) {
      baseMap.set(insts[i].epochDay, insts[i].typeId);
    }
    const cells: DayCell[] = [];
    for (let d = 1; d <= dim; d++) {
      const ed = start + d - 1;
      const hasOver = this.overMap.has(ed);
      let over: string | null = null;
      if (hasOver) {
        const raw = this.overMap.get(ed);
        over = raw === undefined ? null : raw;
      }
      const baseRaw = baseMap.get(ed);
      const base = baseRaw === undefined ? '' : baseRaw;
      const eff = over !== null ? over : base;
      cells.push(new DayCell(d, ed, base, over, this.colorOf(eff), this.labelOf(eff)));
    }
    this.cells = cells;
  }

  colorOf(typeId: string | null): string {
    if (typeId === null || typeId === '') {
      return '#B8C4CE';
    }
    for (let i = 0; i < this.types.length; i++) {
      if (this.types[i].id === typeId) {
        return this.types[i].color;
      }
    }
    return '#CCCCCC';
  }

  labelOf(typeId: string | null): string {
    if (typeId === null || typeId === '') {
      return '休';
    }
    for (let i = 0; i < this.types.length; i++) {
      if (this.types[i].id === typeId) {
        return this.types[i].name.length > 2 ? this.types[i].name.substring(0, 1) : this.types[i].name;
      }
    }
    return '?';
  }

  brushName(): string {
    if (this.brushId === REST_KEY) {
      return '休息';
    }
    return this.labelOf(this.brushId === '' ? null : this.brushId);
  }

  // ---------- 乐观更新 + 防抖批量持久化 ----------

  /** 涂抹：立即更新内存单元格（乐观 UI），覆盖写入进入防抖队列批量落库。 */
  paint(epochDay: number): void {
    if (this.brushId === '') {
      promptAction.showToast({ message: '先在顶部选择画笔（班次/休息）' });
      return;
    }
    const over: string | null = this.brushId === REST_KEY ? null : this.brushId;
    this.applyCellOverride(epochDay, over);
    this.dirtyUpsert.set(epochDay, over);
    this.dirtyDelete.delete(epochDay);
    this.schedulePersist();
  }

  /** 长按清除：已有覆盖 → 移除（回到循环层）；循环班次日 → 写入"休息"覆盖。 */
  clearCell(epochDay: number): void {
    if (this.overMap.has(epochDay)) {
      this.applyCellRevert(epochDay);
      this.dirtyDelete.add(epochDay);
      this.dirtyUpsert.delete(epochDay);
    } else {
      this.applyCellOverride(epochDay, null);
      this.dirtyUpsert.set(epochDay, null);
      this.dirtyDelete.delete(epochDay);
    }
    this.schedulePersist();
  }

  /** 原地更新单元格的覆盖层（不替换对象，@ObjectLink 子组件直接刷新）。 */
  applyCellOverride(epochDay: number, over: string | null): void {
    this.overMap.set(epochDay, over);
    const idx = epochDay - this.monthStart;
    if (idx < 0 || idx >= this.cells.length) {
      return;
    }
    const cell = this.cells[idx];
    const eff = over !== null ? over : cell.baseId;
    cell.overId = over;
    cell.color = this.colorOf(eff);
    cell.label = this.labelOf(eff);
  }

  /** 移除覆盖层，回到循环层效果。 */
  applyCellRevert(epochDay: number): void {
    this.overMap.delete(epochDay);
    const idx = epochDay - this.monthStart;
    if (idx < 0 || idx >= this.cells.length) {
      return;
    }
    const cell = this.cells[idx];
    cell.overId = null;
    cell.color = this.colorOf(cell.baseId);
    cell.label = this.labelOf(cell.baseId);
  }

  /** 批量落库 + 重算的防抖调度（拖动连刷 N 格只落一次库、重算一次）。 */
  schedulePersist(): void {
    if (this.persistTimer >= 0) {
      clearTimeout(this.persistTimer);
    }
    this.persistTimer = setTimeout(() => {
      this.persistTimer = -1;
      this.flushPersist();
    }, PERSIST_DEBOUNCE_MS);
  }

  /** 冲刷待落库变更：批量写覆盖 → 触发重算（US6 / FR-011）；失败 toast 并保留内存态。 */
  async flushPersist(): Promise<void> {
    if (this.dirtyUpsert.size === 0 && this.dirtyDelete.size === 0) {
      return;
    }
    const upserts: Map<number, string | null> = new Map(this.dirtyUpsert);
    const deletes: Set<number> = new Set(this.dirtyDelete);
    this.dirtyUpsert.clear();
    this.dirtyDelete.clear();
    try {
      const delArr: number[] = [];
      deletes.forEach((ed: number) => {
        delArr.push(ed);
      });
      for (let i = 0; i < delArr.length; i++) {
        await ScheduleRepo.deleteOverride(delArr[i], this.owner);
      }
      const upArr: number[] = [];
      upserts.forEach((typeId: string | null, ed: number) => {
        upArr.push(ed);
      });
      for (let i = 0; i < upArr.length; i++) {
        const ed = upArr[i];
        const raw = upserts.get(ed);
        const ov: ScheduleOverride = { epochDay: ed, shiftTypeId: raw === undefined ? null : raw };
        await ScheduleRepo.upsertOverride(ov, '', this.owner);
      }
      ScheduleUseCase.onScheduleChanged().catch((e: Error) => {
        Logger.error('PaintMonth', 'recompute failed: ' + e.message);
      });
    } catch (e) {
      promptAction.showToast({ message: '保存失败，请重试' });
      Logger.error('PaintMonth', 'flush persist failed: ' + (e as Error).message);
    }
  }

  /** 拖动起点（按下所在格）：立即涂首格并记录行内下标。 */
  onPanStart(epochDay: number): void {
    this.lastPainted = epochDay - this.monthStart;
    this.paint(epochDay);
  }

  /** 从起点单元格按拖动偏移推算目标格并刷色（origin 为手势起点格，组件未重建、引用稳定）。 */
  onPanMove(originEpochDay: number, offsetX: number, offsetY: number): void {
    if (this.gridW <= 0) {
      return;
    }
    const originIdx = originEpochDay - this.monthStart;
    if (originIdx < 0) {
      return;
    }
    const cellW = this.gridW / 7;
    const dCol = Math.round(offsetX / cellW);
    const dRow = Math.round(offsetY / ROW_H);
    const idx = originIdx + dRow * 7 + dCol;
    if (idx < 0 || idx >= this.cells.length || idx === this.lastPainted) {
      return;
    }
    this.lastPainted = idx;
    this.paint(this.cells[idx].epochDay);
  }

  changeMonth(delta: number): void {
    let m = this.month + delta;
    let y = this.year;
    if (m > 12) {
      m = 1;
      y++;
    }
    if (m < 1) {
      m = 12;
      y--;
    }
    this.month = m;
    this.year = y;
    this.loadMonth();
  }

  build() {
    Column() {
      Row() {
        Row({ space: 2 }) {
          SymbolGlyph($r('sys.symbol.chevron_left')).fontSize(16).fontColor([$r('app.color.brand_pink')])
          Text('返回').fontSize(15).fontColor($r('app.color.brand_pink'))
        }.onClick(() => router.back())
        Blank()
        Text(this.owner === OWNER_ME ? '月历涂抹' : 'TA 的月历涂抹').fontSize(17).fontWeight(FontWeight.Bold)
        Blank()
        Text(' ')
      }.width('100%').padding(12)

      // 画笔选择
      Scroll() {
        Row({ space: 8 }) {
          Text('画笔:').fontSize(13).fontColor($r('app.color.text_secondary'))
          ForEach(this.types, (st: ShiftType) => {
            Text(st.name)
              .fontSize(12).fontColor('#FFFFFF')
              .padding({ left: 10, right: 10, top: 5, bottom: 5 })
              .borderRadius(12)
              .backgroundColor(this.brushId === st.id ? st.color : $r('app.color.divider'))
              .onClick(() => this.brushId = st.id)
          }, (st: ShiftType) => st.id)
          Text('休息')
            .fontSize(12).fontColor('#FFFFFF')
            .padding({ left: 10, right: 10, top: 5, bottom: 5 })
            .borderRadius(12)
            .backgroundColor(this.brushId === REST_KEY ? '#B8C4CE' : $r('app.color.divider'))
            .onClick(() => this.brushId = REST_KEY)
        }
      }.width('100%').scrollable(ScrollDirection.Horizontal).padding({ left: 12, right: 12 })

      // 月份导航
      Row() {
        Text('‹').fontSize(20).onClick(() => this.changeMonth(-1)).padding(10)
        Blank()
        Text(this.year + ' 年 ' + this.month + ' 月').fontSize(16).fontWeight(FontWeight.Medium)
        Blank()
        Text('›').fontSize(20).onClick(() => this.changeMonth(1)).padding(10)
      }.width('100%').padding({ left: 12, right: 12, top: 6, bottom: 6 })

      // 星期表头
      Row() {
        ForEach(WD_HEAD, (w: string) => {
          Text(w).fontSize(12).fontColor($r('app.color.text_tertiary'))
            .textAlign(TextAlign.Center).layoutWeight(1)
        }, (w: string) => w)
      }.width('100%').padding({ left: 6, right: 6 })

      // 日历网格（支持拖动连刷）
      Column() {
        ForEach(this.weekRows(), (rowCells: (DayCell | null)[], rowIdx: number) => {
          Row() {
            ForEach(rowCells, (cell: DayCell | null) => {
              if (cell === null) {
                Column().layoutWeight(1).height(ROW_H)
              } else {
                DayCellView({
                  cell: cell,
                  isToday: cell.epochDay === todayEpochDay(),
                  onTap: (ed: number) => this.paint(ed),
                  onPanStart: (ed: number) => this.onPanStart(ed),
                  onPanMove: (ed: number, dx: number, dy: number) => this.onPanMove(ed, dx, dy),
                  onLongPress: (ed: number) => this.clearCell(ed)
                })
              }
            }, (cell: DayCell | null, i: number) => rowIdx + '-' + i + '-' + (cell != null ? '' + cell.day : 'x'))
          }.width('100%')
        }, (rowCells: (DayCell | null)[], rowIdx: number) => 'row' + rowIdx)
      }
      .width('100%')
      .padding({ left: 6, right: 6 })
      .onAreaChange((oldArea: Area, newArea: Area) => {
        this.gridW = Number(newArea.width) - 12;
      })

      Text('拖动连续标记 · 点按单日标记 · 长按清除（带“改”角的为手动覆盖）')
        .fontSize(11).fontColor($r('app.color.text_hint')).padding(10)

      Blank()
    }
    .width('100%').height('100%').backgroundColor($r('app.color.page_bg_warm'))
  }

  weekRows(): (DayCell | null)[][] {
    const rows: (DayCell | null)[][] = [];
    const total = this.leadingBlanks + this.cells.length;
    const rowsCount = Math.ceil(total / 7);
    for (let r = 0; r < rowsCount; r++) {
      const row: (DayCell | null)[] = [];
      for (let c = 0; c < 7; c++) {
        const idx = r * 7 + c - this.leadingBlanks;
        row.push(idx >= 0 && idx < this.cells.length ? this.cells[idx] : null);
      }
      rows.push(row);
    }
    return rows;
  }
}

/**
 * 单日格子（独立子组件）：@ObjectLink 监听同一 DayCell 对象的原地属性修改，
 * 涂抹时仅刷新自身视觉，不重建组件——保证拖动手势跨格连刷不中断。
 */
@Component
struct DayCellView {
  @ObjectLink cell: DayCell;
  isToday: boolean = false;
  onTap: (epochDay: number) => void = () => {
  };
  onPanStart: (epochDay: number) => void = () => {
  };
  onPanMove: (epochDay: number, dx: number, dy: number) => void = () => {
  };
  onLongPress: (epochDay: number) => void = () => {
  };

  isRestColor(): boolean {
    return this.cell.color === '#B8C4CE' || this.cell.color === '#CCCCCC';
  }

  build() {
    Column({ space: 2 }) {
      Text('' + this.cell.day)
        .fontSize(13)
        .fontColor(this.isRestColor() ? $r('app.color.text_secondary') : '#FFFFFF')
      if (this.cell.label !== '') {
        Text(this.cell.label).fontSize(9).fontColor('#FFFFFF')
      }
      if (this.cell.overId !== null) {
        Circle().width(4).height(4).fill($r('app.color.danger_red'))
      }
    }
    .justifyContent(FlexAlign.Center)
    .layoutWeight(1)
    .height(ROW_H)
    .margin(2)
    .borderRadius(10)
    .backgroundColor(this.isRestColor() ? $r('app.color.fill_weak') : this.cell.color)
    .border(this.isToday ? { width: 2, color: $r('app.color.brand_pink') } : { width: 0 })
    .onClick(() => this.onTap(this.cell.epochDay))
    .gesture(PanGesture({ direction: PanDirection.All, distance: 8 })
      .onActionStart(() => {
        this.onPanStart(this.cell.epochDay);
      })
      .onActionUpdate((e: GestureEvent) => {
        this.onPanMove(this.cell.epochDay, Number(e.offsetX), Number(e.offsetY));
      }))
    .parallelGesture(LongPressGesture({ duration: 450 })
      .onAction(() => {
        this.onLongPress(this.cell.epochDay);
      }))
  }
}
