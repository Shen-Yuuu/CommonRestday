import { util } from '@kit.ArkTS';
import { OWNER_ME, RosterDay, ShiftSegment, ShiftType, rosterError, rosterSnapshot, shiftSnapshot, shiftSegments, minToHHmm, todayEpochDay, epochDayOf } from 'domain';
import { ScheduleRepo } from 'data';
import { DateLabel } from 'commons';
import { WeeklyRosterService, RosterSaveResult, ScheduleUseCase } from 'feature';
import { DesignTokens } from '../theme/DesignTokens';
import { TimeSegmentsEditor } from './TimeSegmentsEditor';
import { LatestLanding } from '../util/LatestLanding';
import { appToast } from '../util/AppToast';
import { askConfirm } from '../util/AppConfirm';

/** 日期编辑共用一份 UI；周班表回传草稿，首页及周历直接保存该日。 */
@Component
export struct DayShiftSheet {
  @StorageProp('crd_bottom_safe_vp') private bottomSafe: number = 16;
  @StorageProp('crd_window_height_vp') private windowHeight: number = 640;
  @Prop enclosingHeader: number = 0;
  @Prop @Watch('reload') owner: string = OWNER_ME;
  @Prop @Watch('reload') epochDay: number = 0;
  @Prop draft: RosterDay = {epochDay:-1,status:'UNKNOWN',entries:[]};
  @Prop commitImmediately: boolean = true;
  onDraft: (day: RosterDay) => void = () => {};
  onClose: () => void = () => {};
  @State private selectedDay: number = 0;
  @State private day: RosterDay = {epochDay:0,status:'UNKNOWN',entries:[]};
  @State private types: ShiftType[] = [];
  @State private loading: boolean = true;
  @State private failed: boolean = false;
  @State private saving: boolean = false;
  @State private custom: boolean = false;
  @State private customName: string = '';
  @State private editingEntryId: string = '';
  @State private customSegments: ShiftSegment[] = [{startMin:540,endMin:720,crossDay:false}];
  @State private feedback: string = '';
  @State private warning: boolean = false;
  private landing: LatestLanding = new LatestLanding();
  private original: string = '';
  // FIT_CONTENT cannot derive its height from a wrap-content Scroll that also shrinks.
  private editorHeight(): number { return Math.max(180,Math.min(720,this.windowHeight*0.82)-this.enclosingHeader); }
  aboutToAppear(): void {this.reload();}
  private mounted: boolean = false;
  aboutToDisappear(): void {this.mounted=false;this.landing.begin();}
  reload(): void {this.mounted=true;this.selectedDay=this.epochDay>0?this.epochDay:todayEpochDay();this.load();}
  async load(): Promise<void> {
    const token=this.landing.begin(),day=this.selectedDay,owner=this.owner;this.loading=true;this.feedback='';this.warning=false;this.custom=false;
    try {
      await ScheduleUseCase.ensureSeeded(owner);
      const types=await ScheduleRepo.listShiftTypes(owner);
      const days=await WeeklyRosterService.loadDays(owner,day,1);
      if(!this.landing.isCurrent(token))return;
      this.types=types;this.day=rosterSnapshot(!this.commitImmediately && this.draft.epochDay===day?this.draft:days[0]);this.original=JSON.stringify(this.day);this.failed=false;
    }catch(e){if(this.landing.isCurrent(token)){this.failed=true;this.feedback='这次没有读到班表，请重试；已有内容保留';}}
    finally{if(this.landing.isCurrent(token))this.loading=false;}
  }
  private pickDate(): void {
    if(this.saving || !this.commitImmediately)return;
    const d=DateLabel.ymd(this.selectedDay);
    this.getUIContext().showDatePickerDialog({selected:new Date(d.y,d.m-1,d.d),
      onDateAccept:(date: Date) => {
        if(!this.mounted||this.saving)return;
        const next=epochDayOf(date.getFullYear(),date.getMonth()+1,date.getDate());
        if(next===this.selectedDay)return;
        const apply=(): void => {if(!this.mounted||this.saving)return;this.selectedDay=next;this.load();};
        if(this.custom||JSON.stringify(this.day)!==this.original)askConfirm(this.getUIContext(),{
          message:'当天有未保存的修改。放弃草稿并切换日期？',confirmText:'放弃草稿',onConfirm:apply});
        else apply();
      }});
  }
  private times(st: ShiftType): string {return shiftSegments(st).map((s: ShiftSegment): string => minToHHmm(s.startMin)+'–'+(s.crossDay||s.endMin<=s.startMin?'次日 ':'')+minToHHmm(s.endMin)).join(' / ');}
  private add(st: ShiftType): void {
    if(this.saving || this.loading || this.failed)return;
    const next=rosterSnapshot(this.day),snapshot=shiftSnapshot(st);snapshot.id=util.generateRandomUUID();
    if(this.editingEntryId!=='') {
      snapshot.id=this.editingEntryId;
      next.entries=next.entries.map((entry: ShiftType): ShiftType => entry.id===this.editingEntryId?snapshot:entry);
    } else {
      next.entries.push(snapshot);
    }
    next.status='WORK';const invalid=rosterError([next]);
    if(invalid!==''){this.feedback=invalid;return;}
    this.day=next;this.custom=false;this.editingEntryId='';this.feedback='';this.warning=false;
  }
  private status(value: string): void {
    if(this.saving)return;
    const apply=(): void => {if(!this.mounted||this.saving)return;this.day={epochDay:this.selectedDay,status:value,entries:[]};this.feedback='';this.warning=false;};
    if(this.day.entries.length>0) askConfirm(this.getUIContext(),{message:'将移除当天的工作班次，个人安排会保留。确认改为'+(value==='REST'?'休息':'未安排')+'？',confirmText:'确认更改',onConfirm:apply});
    else apply();
  }
  private addCustom(): void {
    const current=this.day.entries.find((entry: ShiftType): boolean => entry.id===this.editingEntryId);
    const st=current!=null?shiftSnapshot(current):ScheduleUseCase.mkType(util.generateRandomUUID(),this.customName.trim(),'#83A8D5',
      this.customSegments[0].startMin,this.customSegments[0].endMin,this.customSegments[0].crossDay,0,0,0);
    st.name=this.customName.trim();st.startMin=this.customSegments[0].startMin;st.endMin=this.customSegments[0].endMin;
    st.crossDay=this.customSegments[0].crossDay;
    st.segments=this.customSegments;this.add(st);
  }
  private async save(): Promise<void> {
    if(this.saving || this.loading || this.failed)return;
    if(!this.commitImmediately){this.onDraft(rosterSnapshot(this.day));this.onClose();return;}
    const day=this.selectedDay,owner=this.owner;this.saving=true;
    const result: RosterSaveResult=await WeeklyRosterService.saveDays(owner,[this.day],this.warning);
    this.saving=false;
    if(!this.mounted || this.selectedDay!==day || this.owner!==owner)return;
    this.feedback=result.message;this.warning=result.warning;
    if(result.changed){appToast(result.ok?'已保存当天安排':result.message);this.onClose();}
  }
  @Builder
  shiftSelection() {
    Column({space:14}) {
      Row() {
        Button(DateLabel.mdw(this.selectedDay)+(this.commitImmediately?' ›':''))
          .fontSize(20).fontWeight(FontWeight.Bold).fontColor(DesignTokens.textPrimary)
          .backgroundColor(Color.Transparent).stateEffect(false).layoutWeight(1).height(44).onClick(() => this.pickDate())
        Button('关闭').height(40).fontSize(13).backgroundColor(DesignTokens.fillWeak).fontColor(DesignTokens.textPrimary)
          .enabled(!this.saving).onClick(() => this.onClose())
      }.width('100%')
      if(this.loading){Text('正在读取班表…').fontColor(DesignTokens.textSecondary)}
      else if(this.failed){Button('重新读取').onClick(() => this.load())}
      else if(this.custom){
        Row({space:12}) {
          Text('名称').fontSize(13).fontColor(DesignTokens.textSecondary)
          TextInput({text:this.customName,placeholder:'如：加班、门诊班'}).layoutWeight(1).maxLength(30)
            .onChange((value: string) => {this.customName=value;this.feedback='';})
        }.width('100%')
        TimeSegmentsEditor({segments:this.customSegments,editable:!this.saving,
          onChange:(parts: ShiftSegment[]) => {this.customSegments=parts;this.feedback='';}})
      }else{
        Row({space:10}) {
          Button('休息').height(40).fontSize(13).backgroundColor(this.day.status==='REST'?DesignTokens.shareSelectedBg:DesignTokens.fillWeak)
            .fontColor(DesignTokens.textPrimary).enabled(!this.saving).onClick(() => this.status('REST'))
          Button('未安排').height(40).fontSize(13).backgroundColor(this.day.status==='UNKNOWN'?DesignTokens.shareSelectedBg:DesignTokens.fillWeak)
            .fontColor(DesignTokens.textPrimary).enabled(!this.saving).onClick(() => this.status('UNKNOWN'))
        }.width('100%')
        ForEach(this.day.entries,(st: ShiftType) => {
          Row({space:10}) {
            Circle().width(7).height(7).fill(st.color)
            Column({space:4}) {
              Text(st.name).fontSize(15).fontWeight(FontWeight.Medium).fontColor(DesignTokens.textPrimary)
              Text(this.times(st)).fontSize(12).fontColor(DesignTokens.textSecondary)
            }.layoutWeight(1).alignItems(HorizontalAlign.Start).onClick(() => {
              if(this.saving)return;this.editingEntryId=st.id;this.customName=st.name;
              this.customSegments=shiftSegments(shiftSnapshot(st));this.custom=true;this.feedback='';this.warning=false;
            })
            Button('移除').height(40).fontSize(12).backgroundColor(Color.Transparent).fontColor(DesignTokens.textSecondary)
              .enabled(!this.saving).onClick(() => {const next=rosterSnapshot(this.day);next.entries=next.entries.filter((s: ShiftType): boolean => s.id!==st.id);
                next.status=next.entries.length?'WORK':'UNKNOWN';this.day=next;this.feedback='';this.warning=false;})
          }.width('100%').padding(12).borderRadius(16).backgroundColor(DesignTokens.fillWeakest)
        },(st: ShiftType): string => JSON.stringify(st))
        Text('添加一个班次').fontSize(12).fontColor(DesignTokens.textSecondary).width('100%')
        ForEach(this.types,(st: ShiftType) => {
          Row({space:12}) {
            Circle().width(24).height(24).fill(st.color).opacity(0.7)
            Column({space:3}) {
              Text(st.name).fontSize(14).fontWeight(FontWeight.Medium).fontColor(DesignTokens.textPrimary)
              Text(this.times(st)).fontSize(11).fontColor(DesignTokens.textSecondary)
            }.layoutWeight(1).alignItems(HorizontalAlign.Start)
            Text('＋').fontSize(22).fontColor(DesignTokens.primary)
          }.width('100%').padding(12).border({width:1,color:DesignTokens.borderWeak}).borderRadius(16)
            .clickEffect(DesignTokens.tapChip())
            .enabled(!this.saving).onClick(() => this.add(st))
        },(st: ShiftType): string => JSON.stringify(st))
        Button('＋ 自填工作时间').width('100%').height(44).backgroundColor(Color.Transparent).fontColor(DesignTokens.primary)
          .enabled(!this.saving).onClick(() => {this.custom=true;this.editingEntryId='';this.customName='';this.customSegments=[{startMin:540,endMin:720,crossDay:false}];})
      }
      if(this.feedback!==''){Text(this.feedback).width('100%').fontSize(12).fontColor(this.warning?DesignTokens.warn:DesignTokens.danger)}
    }.width('100%').alignItems(HorizontalAlign.Start).padding({left:20,right:20,top:18,bottom:12}).backgroundColor(DesignTokens.card)
  }
  @Builder
  safeFooter() {
    Row({space:10}) {
      if(this.custom) {
        Button('返回').layoutWeight(1).height(46).backgroundColor(DesignTokens.fillWeak).fontColor(DesignTokens.textPrimary)
          .enabled(!this.saving).onClick(() => this.custom=false)
        Button(this.editingEntryId!==''?'更新这个班次':'加入当天').layoutWeight(1).height(46)
          .backgroundColor(DesignTokens.primary).fontColor(DesignTokens.heroText)
          .enabled(!this.saving).onClick(() => this.addCustom())
      } else {
        Button(this.saving?'保存中…':this.warning?'仍然保存':this.commitImmediately?'保存当天安排':'完成本日安排')
          .layoutWeight(1).height(46).backgroundColor(DesignTokens.primary).fontColor(DesignTokens.heroText)
          .fontWeight(FontWeight.Bold).enabled(!this.loading&&!this.failed&&!this.saving).onClick(() => this.save())
      }
    }.width('100%').padding({left:20,right:20,top:10,bottom:Math.max(12,this.bottomSafe+12)})
      .backgroundColor(DesignTokens.card).flexShrink(0)
  }
  build() {
    Column() {
      Scroll(){this.shiftSelection()}.width('100%').layoutWeight(1)
        .align(Alignment.TopStart).scrollBar(BarState.Off)
      this.safeFooter()
    }.width('100%').height(this.editorHeight())
      .backgroundColor(DesignTokens.card)
  }
}
