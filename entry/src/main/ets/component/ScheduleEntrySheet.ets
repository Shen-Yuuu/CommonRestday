import { util } from '@kit.ArkTS';
import { MIN_PER_DAY, OWNER_ME, PersonalEntry, ShiftSegment, dayOfStart, epochDayOf, todayEpochDay } from 'domain';
import { WeeklyRosterService } from 'feature';
import { DateLabel } from 'commons';
import { DesignTokens } from '../theme/DesignTokens';
import { DayShiftSheet } from './DayShiftSheet';
import { TimeSegmentsEditor } from './TimeSegmentsEditor';
import { appToast } from '../util/AppToast';
import { askConfirm } from '../util/AppConfirm';

@Component
export struct ScheduleEntrySheet {
  onClose: () => void = () => {};
  @State private mode: string = 'choose';
  @State private day: number = todayEpochDay();
  @State private title: string = '';
  @State private kind: string = '运动';
  @State private segments: ShiftSegment[] = [{startMin:1140,endMin:1200,crossDay:false}];
  @State private busy: boolean = false;
  @State private feedback: string = '';
  @State private warning: boolean = false;
  @State private personal: PersonalEntry[] = [];
  @State private editingId: string = '';
  private mounted: boolean = false;
  aboutToAppear(): void {this.mounted=true;this.reload();}
  aboutToDisappear(): void {this.mounted=false;}
  private async reload(): Promise<void> {
    try{const state=await WeeklyRosterService.read(OWNER_ME);if(this.mounted)this.personal=state.personal;}
    catch(e){if(this.mounted)this.feedback='个人日程暂未读取成功，请关闭后重试';}
  }
  private pickDate(): void {
    if(this.busy)return;const d=DateLabel.ymd(this.day);
    this.getUIContext().showDatePickerDialog({selected:new Date(d.y,d.m-1,d.d),onDateAccept:(value: Date) => {
      if(!this.mounted||this.busy)return;this.day=epochDayOf(value.getFullYear(),value.getMonth()+1,value.getDate());this.warning=false;this.feedback='';
    }});
  }
  private async save(): Promise<void> {
    if(this.busy)return;
    const segment=this.segments[0];
    const entry: PersonalEntry={id:this.editingId!==''?this.editingId:util.generateRandomUUID(),title:this.title.trim(),kind:this.kind,
      start:this.day*MIN_PER_DAY+segment.startMin,
      end:this.day*MIN_PER_DAY+segment.endMin+(segment.crossDay||segment.endMin<=segment.startMin?MIN_PER_DAY:0)};
    this.busy=true;const result=await WeeklyRosterService.savePersonal(OWNER_ME,entry,this.warning);this.busy=false;
    if(!this.mounted)return;this.feedback=result.message;this.warning=result.warning;
    if(result.changed){appToast(result.ok?'已保存个人日程':result.message);this.onClose();}
  }
  private edit(entry: PersonalEntry): void {
    this.editingId=entry.id;this.title=entry.title;this.kind=entry.kind;this.day=dayOfStart(entry.start);
    this.segments=[{startMin:entry.start%MIN_PER_DAY,endMin:entry.end%MIN_PER_DAY,crossDay:dayOfStart(entry.end)>this.day}];
    this.feedback='';this.warning=false;
  }
  private remove(entry: PersonalEntry): void {
    if(this.busy)return;
    askConfirm(this.getUIContext(),{message:'删除个人日程「'+entry.title+'」？',confirmText:'删除',onConfirm:() => {
      this.busy=true;WeeklyRosterService.removePersonal(OWNER_ME,entry.id).then(result => {
        this.busy=false;if(!this.mounted)return;if(result.changed){this.reload();if(this.editingId===entry.id){this.editingId='';this.title='';}}
        appToast(result.changed?'已删除个人日程':result.message);
      });
    }});
  }
  @Builder
  choice() {
    Column({space:16}) {
      Row(){Text('安排日程').fontSize(24).fontWeight(FontWeight.Bold).layoutWeight(1)
        Button('关闭').height(40).backgroundColor(DesignTokens.fillWeak).fontColor(DesignTokens.textPrimary).onClick(() => this.onClose())}.width('100%')
      this.choiceRow('个人安排','运动、就医、办事等，仅安排自己的时间')
      this.choiceRow('工作排班','添加或调整当天班次')
    }.width('100%').alignItems(HorizontalAlign.Start).padding({left:22,right:22,top:24,bottom:28})
  }
  @Builder
  choiceRow(title: string,description: string) {
    Row({space:12}) {
      SymbolGlyph(title==='个人安排'?$r('sys.symbol.calendar'):$r('sys.symbol.clock')).fontSize(23).fontColor([DesignTokens.planAccent])
      Column({space:6}) {Text(title).fontSize(17).fontWeight(FontWeight.Medium).fontColor(DesignTokens.textPrimary)
        Text(description).fontSize(12).fontColor(DesignTokens.textSecondary)}.layoutWeight(1).alignItems(HorizontalAlign.Start)
      Text('›').fontSize(22).fontColor(DesignTokens.textTertiary)
    }.width('100%').padding(17).backgroundColor(DesignTokens.fillWeakest).borderRadius(20)
      .clickEffect(DesignTokens.tapButton())
      .onClick(() => {this.mode=title==='个人安排'?'personal':'work';})
  }
  @Builder
  personalForm() {
    Column({space:14}) {
      Row(){Text(this.editingId!==''?'编辑个人安排':'个人安排').fontSize(22).fontWeight(FontWeight.Bold).layoutWeight(1)
        Button('关闭').height(40).backgroundColor(DesignTokens.fillWeak).fontColor(DesignTokens.textPrimary)
          .enabled(!this.busy).onClick(() => this.onClose())}.width('100%')
      Row({space:6}) {
        ForEach(['运动','就医','办事','其他'],(value: string) => {
          Button(value).layoutWeight(1).height(40).fontSize(12).padding({left:4,right:4}).fontColor(DesignTokens.textPrimary)
            .backgroundColor(this.kind===value?DesignTokens.shareSelectedBg:DesignTokens.fillWeak)
            .enabled(!this.busy).onClick(() => {this.kind=value;this.warning=false;})
        },(value: string): string => value)
      }.width('100%')
      Row({space:12}) {Text('标题').fontSize(13).fontColor(DesignTokens.textSecondary)
        TextInput({text:this.title,placeholder:'如：去练瑜伽'}).layoutWeight(1).maxLength(60).enabled(!this.busy)
          .onChange((value: string) => {this.title=value;this.warning=false;this.feedback='';})}.width('100%')
      Button(DateLabel.mdw(this.day)+' ›').width('100%').height(44).backgroundColor(DesignTokens.fillWeakest)
        .fontColor(DesignTokens.textPrimary).enabled(!this.busy).onClick(() => this.pickDate())
      TimeSegmentsEditor({segments:this.segments,allowMultiple:false,editable:!this.busy,
        onChange:(segments: ShiftSegment[]) => {this.segments=segments;this.warning=false;this.feedback='';}})
      if(this.feedback!==''){Text(this.feedback).fontSize(12).fontColor(this.warning?DesignTokens.warn:DesignTokens.danger)}
      Button(this.busy?'保存中…':this.warning?'仍然保存':'保存日程').width('100%').height(46)
        .backgroundColor(DesignTokens.primary).enabled(!this.busy).onClick(() => this.save())
      if(this.personal.length>0){Text('个人日程').fontSize(12).fontColor(DesignTokens.textSecondary)
        ForEach(this.personal.slice().sort((a: PersonalEntry,b: PersonalEntry): number => a.start-b.start),(entry: PersonalEntry) => {
          Row({space:10}) {
            Column({space:4}) {Text(entry.title).fontSize(14).fontColor(DesignTokens.textPrimary)
              Text(DateLabel.mdw(dayOfStart(entry.start))).fontSize(11).fontColor(DesignTokens.textSecondary)}
              .layoutWeight(1).alignItems(HorizontalAlign.Start).onClick(() => {if(!this.busy)this.edit(entry);})
            Button('删除').height(40).fontSize(12).backgroundColor(Color.Transparent).fontColor(DesignTokens.danger)
              .enabled(!this.busy).onClick(() => this.remove(entry))
          }.width('100%').padding(12).backgroundColor(DesignTokens.fillWeakest).borderRadius(16)
        },(entry: PersonalEntry): string => JSON.stringify(entry))
      }
    }.width('100%').alignItems(HorizontalAlign.Start).padding({left:20,right:20,top:22,bottom:24})
  }
  build() {
    if(this.mode==='work'){DayShiftSheet({owner:OWNER_ME,epochDay:this.day,onClose:() => this.onClose()})}
    else{
      Scroll(){if(this.mode==='choose'){this.choice()}else{this.personalForm()}}
        .width('100%').height(LayoutPolicy.wrapContent).flexShrink(1).scrollBar(BarState.Off).backgroundColor(DesignTokens.card)
    }
  }
}
