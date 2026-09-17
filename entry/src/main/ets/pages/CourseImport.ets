import { DatePickerComponent, DatePickerComponentResult, DateMode, DisplayMode, promptAction, router } from '@kit.ArkUI';
import { util } from '@kit.ArkTS';
import {
  OWNER_ME, Course, ParsedCourseLine, SectionTime, hhmmToMin, minToHHmm,
  parseCourseText, toCourse
} from 'domain';
import { ScheduleRepo } from 'data';
import { DateLabel } from 'commons';
import { ScheduleUseCase, TermConfig } from 'feature';
import { ownerFromParams, OwnerRouteParam } from '../model/RouteParams';

/** 课程表导入：学期锚点 + 节次模板 + 粘贴文本解析 + 手动添加 + 课程列表（owner 双侧复用）。 */
@Entry
@Component
struct CourseImport {
  @State owner: string = OWNER_ME;
  @State termStart: number = -1;
  @State pasteText: string = '';
  @State parsed: ParsedCourseLine[] = [];
  @State courses: Course[] = [];
  @State manualName: string = '';
  @State manualWd: number = 1;
  @State manualSecFrom: number = 1;
  @State manualSecTo: number = 2;
  @State manualWeekFrom: string = '1';
  @State manualWeekTo: string = '16';
  // 节次模板编辑器（每行一节 "HH:MM-HH:MM"）
  @State showSections: boolean = false;
  @State sectionText: string = '';
  // 学期起点 sheet（DatePickerComponent，API 26）：临时选择值，确认才保存
  @State termSheetVisible: boolean = false;
  @State termPick: number = -1;

  aboutToAppear(): void {
    this.owner = ownerFromParams(router.getParams());
    this.reload();
  }

  async reload(): Promise<void> {
    this.courses = await ScheduleRepo.listCourses(this.owner);
    this.termStart = await ScheduleRepo.getTermStart();
    // 当前生效节次模板：已保存值优先，否则默认模板
    this.sectionText = this.formatSectionText(
      ScheduleUseCase.sectionTimesFromJson(await ScheduleRepo.getSectionTimes()));
  }

  /** SectionTime[] → 每行 "HH:MM-HH:MM" 的编辑文本。 */
  formatSectionText(times: SectionTime[]): string {
    const parts: string[] = [];
    for (let i = 0; i < times.length; i++) {
      parts.push(minToHHmm(times[i].startMin) + '-' + minToHHmm(times[i].endMin));
    }
    return parts.join('\n');
  }

  /** 编辑文本 → SectionTime[]；任何一行非法返回 null。 */
  parseSectionText(text: string): SectionTime[] | null {
    const lines = text.split('\n');
    const out: SectionTime[] = [];
    for (let i = 0; i < lines.length; i++) {
      const line = lines[i].trim();
      if (line === '') {
        continue;
      }
      const parts = line.split('-');
      if (parts.length !== 2) {
        return null;
      }
      const s = hhmmToMin(parts[0].trim());
      const e = hhmmToMin(parts[1].trim());
      if (s < 0 || e < 0 || e <= s) {
        return null;
      }
      const st: SectionTime = { startMin: s, endMin: e };
      out.push(st);
    }
    return out.length === 0 ? null : out;
  }

  /** 保存自定义节次模板（需先设置学期起点；节次与学期锚点同存 term_config 单行）。 */
  async saveSections(): Promise<void> {
    if (this.termStart <= 0) {
      promptAction.showToast({ message: '请先设置学期起点' });
      return;
    }
    const times = this.parseSectionText(this.sectionText);
    if (times == null) {
      promptAction.showToast({ message: '节次格式有误：每行一节，形如 08:00-08:45' });
      return;
    }
    await ScheduleUseCase.saveTermConfig(this.termStart, times);
    promptAction.showToast({ message: '节次时间已保存' });
    this.reload();
    this.recomputeAfterSave();
  }

  /** 恢复默认节次模板（仅填充编辑区，点"保存节次"才落库）。 */
  resetSections(): void {
    this.sectionText = this.formatSectionText(ScheduleUseCase.defaultSectionTimes());
  }

  doParse(): void {
    this.parsed = parseCourseText(this.pasteText);
    if (this.parsed.length === 0) {
      promptAction.showToast({ message: '没有可解析的内容' });
    }
  }

  async saveParsed(): Promise<void> {
    let n = 0;
    for (let i = 0; i < this.parsed.length; i++) {
      if (this.parsed[i].ok) {
        await ScheduleRepo.upsertCourse(toCourse(this.parsed[i], util.generateRandomUUID()), this.owner);
        n++;
      }
    }
    promptAction.showToast({ message: '已导入 ' + n + ' 门课程' });
    this.parsed = [];
    this.pasteText = '';
    this.reload();
    this.recomputeAfterSave();
  }

  async saveManual(): Promise<void> {
    if (this.manualName === '') {
      promptAction.showToast({ message: '请填写课程名' });
      return;
    }
    const wf = Number.parseInt(this.manualWeekFrom, 10);
    const wt = Number.parseInt(this.manualWeekTo, 10);
    const c: Course = {
      id: util.generateRandomUUID(),
      name: this.manualName,
      weekday: this.manualWd,
      sectionStart: this.manualSecFrom,
      sectionEnd: this.manualSecTo,
      weekFrom: Number.isNaN(wf) ? 1 : wf,
      weekTo: Number.isNaN(wt) ? 16 : wt,
      parity: 0,
      place: ''
    };
    await ScheduleRepo.upsertCourse(c, this.owner);
    this.manualName = '';
    promptAction.showToast({ message: '已添加' });
    this.reload();
    this.recomputeAfterSave();
  }

  async removeCourse(id: string): Promise<void> {
    await ScheduleRepo.deleteCourse(id, this.owner);
    this.reload();
    this.recomputeAfterSave();
  }

  /** 保存/删除动作 → 自动重算（US6 / FR-011，ME/PARTNER 两侧一致触发）。 */
  recomputeAfterSave(): void {
    ScheduleUseCase.onScheduleChanged().catch((e: Error) => {
      promptAction.showToast({ message: '重算失败：' + e.message });
    });
  }

  /** 打开学期起点 sheet：DatePickerComponent 滚轮选值（带触感反馈），确认后保存。 */
  pickTermStart(): void {
    this.termPick = this.termStart;
    this.termSheetVisible = true;
  }

  /** 确认学期起点：保留已自定义的节次模板（仅当未自定义时写入默认模板）。 */
  confirmTermStart(): void {
    const ed = this.termPick;
    this.termSheetVisible = false;
    if (ed <= 0) {
      return;
    }
    ScheduleRepo.getSectionTimes().then((json: string) => {
      // 保留已自定义节次；未保存过（空串/解析失败）时回退默认模板
      return ScheduleUseCase.saveTermConfig(ed, ScheduleUseCase.sectionTimesFromJson(json));
    }).then(() => {
      promptAction.showToast({ message: '学期起点已保存' });
      this.reload();
      this.recomputeAfterSave();
    });
  }

  build() {
    Column() {
      Row() {
        Row({ space: 2 }) {
          SymbolGlyph($r('sys.symbol.chevron_left')).fontSize(16).fontColor([$r('app.color.brand_pink')])
          Text('返回').fontSize(15).fontColor($r('app.color.brand_pink'))
        }.onClick(() => router.back())
        Blank()
        Text(this.owner === OWNER_ME ? '课程表导入' : 'TA 的课程表导入').fontSize(17).fontWeight(FontWeight.Bold)
        Blank()
        Text('拍照识别').fontSize(14).fontColor($r('app.color.info_blue'))
          .onClick(() => {
            const p: OwnerRouteParam = { owner: this.owner };
            router.pushUrl({ url: 'pages/OcrCourse', params: p });
          })
      }.width('100%').padding(12)

      List({ space: 12 }) {
        // 学期配置
        ListItem() {
          Column({ space: 8 }) {
            Text('学期起点（第一周周一）').fontSize(13).fontColor($r('app.color.text_tertiary')).width('100%')
            Row() {
              Text(this.termStart > 0 ? DateLabel.mdw(this.termStart) : '未设置').fontSize(15)
              Blank()
              Text('选择 ›').fontSize(13).fontColor($r('app.color.brand_pink'))
            }
            .width('100%').padding(10).borderRadius(10).backgroundColor($r('app.color.fill_weakest'))
            .onClick(() => this.pickTermStart())

            // 节次模板（可编辑；默认上午 8:00 起、下午 14:00 起、晚上 19:00 起，每节 45+10 分钟）
            Row() {
              Text('节次时间模板').fontSize(13).fontColor($r('app.color.text_secondary'))
              Blank()
              Text(this.showSections ? '收起 ›' : '编辑 ›').fontSize(13).fontColor($r('app.color.brand_pink'))
            }
            .width('100%')
            .onClick(() => this.showSections = !this.showSections)

            if (this.showSections) {
              TextArea({ text: this.sectionText, placeholder: '每行一节，形如 08:00-08:45' })
                .height(120).fontSize(12).width('100%')
                .onChange((v: string) => this.sectionText = v)
              Row({ space: 10 }) {
                Button('保存节次').backgroundColor($r('app.color.info_blue')).height(34)
                  .onClick(() => this.saveSections())
                Button('恢复默认').backgroundColor($r('app.color.fill_weak')).fontColor($r('app.color.text_secondary')).height(34)
                  .onClick(() => this.resetSections())
              }
              Text('第 N 节对应第 N 行；课程按"第 X-X 节"映射到这里的起止时间。')
                .fontSize(11).fontColor($r('app.color.text_hint'))
            } else {
              Text('默认模板：上午 8:00 起、下午 14:00 起、晚上 19:00 起，每节 45+10 分钟；点"编辑"可自定义。')
                .fontSize(11).fontColor($r('app.color.text_hint'))
            }
          }
          .width('100%').padding(12).borderRadius(16)
          .backgroundColor($r('app.color.card_bg'))
          .shadow({ radius: 16, color: $r('app.color.shadow_soft'), offsetX: 0, offsetY: 4 })
        }

        // 粘贴导入
        ListItem() {
          Column({ space: 8 }) {
            Text('粘贴课表文本（每行一门：课程名 周X 第X-X节 周次范围 单/双周）')
              .fontSize(13).fontColor($r('app.color.text_tertiary')).width('100%')
            TextArea({ text: this.pasteText, placeholder: '高等数学 周一 第1-2节 1-16周 单周\n大学英语 周三 3,4节' })
              .height(88).fontSize(13).width('100%')
              .onChange((v: string) => this.pasteText = v)
            Row({ space: 10 }) {
              Button('解析预览').backgroundColor($r('app.color.info_blue')).height(36).borderRadius(18)
                .onClick(() => this.doParse())
              Button('保存通过项').backgroundColor($r('app.color.success_green')).height(36).borderRadius(18)
                .onClick(() => this.saveParsed())
            }
            ForEach(this.parsed, (p: ParsedCourseLine) => {
              Row() {
                Text(p.ok ? '✓' : '✗').fontSize(13).fontColor(p.ok ? $r('app.color.success_green') : $r('app.color.danger_red')).width(20)
                Column({ space: 2 }) {
                  Text(p.ok ? p.name + ' · 周' + p.weekday + ' · 第' + p.sectionStart + '-' + p.sectionEnd
                    + '节 · ' + p.weekFrom + '-' + p.weekTo + '周' : p.rawLine)
                    .fontSize(13).fontColor($r('app.color.text_primary'))
                  if (!p.ok) {
                    Text(p.error).fontSize(11).fontColor($r('app.color.danger_red'))
                  }
                }.alignItems(HorizontalAlign.Start)
                Blank()
              }.width('100%').padding(8).borderRadius(8).backgroundColor($r('app.color.fill_weakest'))
            }, (p: ParsedCourseLine, i: number) => '' + i + p.rawLine)
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%').padding(12).borderRadius(16)
          .backgroundColor($r('app.color.card_bg'))
          .shadow({ radius: 16, color: $r('app.color.shadow_soft'), offsetX: 0, offsetY: 4 })
        }

        // 手动添加
        ListItem() {
          Column({ space: 8 }) {
            Text('手动添加').fontSize(13).fontColor($r('app.color.text_tertiary')).width('100%')
            TextInput({ text: this.manualName, placeholder: '课程名' })
              .height(38).width('100%')
              .onChange((v: string) => this.manualName = v)
            Row({ space: 6 }) {
              ForEach(['一', '二', '三', '四', '五', '六', '日'], (w: string, i: number) => {
                Text('周' + w).fontSize(12)
                  .padding({ left: 7, right: 7, top: 5, bottom: 5 })
                  .borderRadius(10)
                  .fontColor(this.manualWd === i + 1 ? '#FFFFFF' : $r('app.color.text_secondary'))
                  .backgroundColor(this.manualWd === i + 1 ? $r('app.color.info_blue') : $r('app.color.fill_weak'))
                  .onClick(() => this.manualWd = i + 1)
              }, (w: string) => w)
            }
            Row({ space: 6 }) {
              Text('第').fontSize(13)
              TextInput({ text: '' + this.manualSecFrom }).width(40).height(36)
                .onChange((v: string) => this.manualSecFrom = this.toInt(v, 1))
              Text('—').fontSize(13)
              TextInput({ text: '' + this.manualSecTo }).width(40).height(36)
                .onChange((v: string) => this.manualSecTo = this.toInt(v, 2))
              Text('节').fontSize(13)
              Text('周次').fontSize(13).margin({ left: 8 })
              TextInput({ text: this.manualWeekFrom }).width(44).height(36)
                .onChange((v: string) => this.manualWeekFrom = v)
              Text('—').fontSize(13)
              TextInput({ text: this.manualWeekTo }).width(44).height(36)
                .onChange((v: string) => this.manualWeekTo = v)
            }
            Button('添加课程').width('100%').height(40).borderRadius(20).backgroundColor($r('app.color.info_blue'))
              .onClick(() => this.saveManual())
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%').padding(12).borderRadius(16)
          .backgroundColor($r('app.color.card_bg'))
          .shadow({ radius: 16, color: $r('app.color.shadow_soft'), offsetX: 0, offsetY: 4 })
        }

        // 课程列表（左滑删除）
        ListItem() {
          Text('已添加课程（' + this.courses.length + '）').fontSize(13).fontColor($r('app.color.text_tertiary')).width('100%')
        }
        ForEach(this.courses, (c: Course) => {
          ListItem() {
            Row() {
              Column({ space: 2 }) {
                Text(c.name).fontSize(14).fontWeight(FontWeight.Medium)
                Text('周' + c.weekday + ' · 第' + c.sectionStart + '-' + c.sectionEnd + '节 · '
                  + c.weekFrom + '-' + c.weekTo + '周'
                  + (c.parity === 1 ? ' · 单周' : c.parity === 2 ? ' · 双周' : ''))
                  .fontSize(11).fontColor($r('app.color.text_tertiary'))
              }.alignItems(HorizontalAlign.Start)
              Blank()
              Text('删除').fontSize(13).fontColor($r('app.color.danger_red'))
                .onClick(() => this.removeCourse(c.id))
            }
            .width('100%').padding(10).borderRadius(10).backgroundColor($r('app.color.fill_weakest'))
          }
          .swipeAction({
            end: () => {
              this.courseDelete(c)
            },
            edgeEffect: SwipeEdgeEffect.Spring
          })
        }, (c: Course) => c.id)
      }
      .padding(12).width('100%').layoutWeight(1)
    }
    .width('100%').height('100%').backgroundColor($r('app.color.page_bg_warm'))
    .bindSheet($$this.termSheetVisible, this.termSheet(), {
      detents: [SheetSize.MEDIUM],
      dragBar: false,
      showClose: false,
      blurStyle: BlurStyle.Thick
    })
  }

  /** 学期起点 sheet：DatePickerComponent（API 26）滚轮 + 确认/取消。 */
  @Builder
  termSheet() {
    Column({ space: 12 }) {
      Text('选择学期起点（第一周周一）').fontSize(16).fontWeight(FontWeight.Medium)
      DatePickerComponent({
        options: {
          displayMode: DisplayMode.DATE,
          dateOptions: {
            mode: DateMode.DATE,
            start: new Date(2024, 0, 1),
            end: new Date(2032, 11, 31),
            selected: this.termPick > 0 ? new Date(this.termPick * 86400000) : new Date(),
            onChange: (r: DatePickerComponentResult) => {
              if (r.year != null && r.month != null && r.day != null) {
                this.termPick = Math.floor(Date.UTC(r.year, r.month - 1, r.day) / 86400000);
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
            this.termSheetVisible = false;
          })
        Button('确定').layoutWeight(1).height(42).borderRadius(21)
          .backgroundColor($r('app.color.brand_pink'))
          .onClick(() => this.confirmTermStart())
      }.width('100%')
    }
    .width('100%')
    .padding({ left: 20, right: 20, top: 16, bottom: 28 })
    .backgroundColor($r('app.color.page_bg_warm'))
  }

  /** 左滑露出的"删除"按钮（红色，直接删除已有内联删除兜底）。 */
  @Builder
  courseDelete(c: Course) {
    Row() {
      Text('删除').fontSize(14).fontColor('#FFFFFF')
    }
    .width(72)
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor($r('app.color.danger_red'))
    .borderRadius(10)
    .onClick(() => this.removeCourse(c.id))
  }

  toInt(v: string, dft: number): number {
    const n = Number.parseInt(v, 10);
    return Number.isNaN(n) ? dft : n;
  }
}
