import { OWNER_ME, RosterDay, ShiftSegment, ShiftType, copyRosterWeek, minToHHmm, rosterSnapshot,
  shiftSegments, todayEpochDay, weekMonday, epochDayOf } from 'domain';
import { DateLabel } from 'commons';
import { WeeklyRosterService } from 'feature';
import { ScheduleRepo } from 'data';
import { DesignTokens } from '../theme/DesignTokens';
import { DayShiftSheet } from './DayShiftSheet';
import { WeekNavigator } from './WeekNavigator';
import { LatestLanding } from '../util/LatestLanding';
import { askConfirm } from '../util/AppConfirm';
import { appToast } from '../util/AppToast';

@Component
export struct WeeklyRosterView {
  @Prop @Watch('resetOwner') owner: string = OWNER_ME;
  @State private week: number = weekMonday(todayEpochDay());
  @State private selected: number = todayEpochDay();
  @State private days: RosterDay[] = [];
  @State private loading: boolean = true;
  @State private failed: boolean = false;
  @State private legacy: boolean = false;
  @State @Watch('draftChanged') private dirty: boolean = false;
  onDirty: (dirty: boolean) => void = () => {};
  @State @Watch('busyChanged') private busy: boolean = false;
  onBusy: (busy: boolean) => void = () => {};
  @State private dayOpen: boolean = false;
  @State private copyOpen: boolean = false;
  @State private sheetVisible: boolean = false;
  @State private repeat: boolean = false;
  @State private targets: number[] = [];
  @State private repeatFrom: number = 0;
  @State private repeatTo: number = 0;
  @State private strategy: string = 'KEEP';
  @State private feedback: string = '';
  @State private warning: boolean = false;
  @StorageProp('recomputeCount') @Watch('onRecomputed') recomputeCount: number = 0;
  private landing: LatestLanding = new LatestLanding();
  private pendingCopy: RosterDay[] = [];
  aboutToAppear(): void {this.load();}
  aboutToDisappear(): void {this.landing.begin();}
  private draftChanged(): void { this.onDirty(this.dirty); }
  private busyChanged(): void { this.onBusy(this.busy); }
  private resetOwner(): void {this.dirty=false;this.closeSheet();this.load();}
  private onRecomputed(): void {if(!this.busy && !this.dirty && !this.sheetVisible)this.load();}
  private closeSheet(): void {this.sheetVisible=false;this.dayOpen=false;this.copyOpen=false;}
  private async load(): Promise<void> {
    const token=this.landing.begin(),owner=this.owner,week=this.week;this.loading=true;
    try{const days=await WeeklyRosterService.loadDays(owner,week,7);const template=await ScheduleRepo.getTemplate(owner);
      if(!this.landing.isCurrent(token))return;this.days=days;this.legacy=template!==null;this.failed=false;this.feedback='';this.warning=false;
    }catch(e){if(this.landing.isCurrent(token)){this.failed=true;this.feedback='班表暂未读取成功，请重试';}}
    finally{if(this.landing.isCurrent(token))this.loading=false;}
  }
  private changeWeek(day: number): void {
    if(this.busy || this.loading)return;
    const apply=(): void => {this.week=weekMonday(day);this.selected=day;this.dirty=false;this.load();};
    if(this.dirty)askConfirm(this.getUIContext(),{message:'这一周有未保存的修改。放弃草稿并切换周？',confirmText:'放弃草稿',onConfirm:apply});else apply();
  }
  private dayOf(day: number): RosterDay {return this.days.find((d: RosterDay): boolean => d.epochDay===day)??{epochDay:day,status:'UNKNOWN',entries:[]};}
  private time(st: ShiftType): string {return shiftSegments(st).map((s: ShiftSegment): string => minToHHmm(s.startMin)+'–'+(s.crossDay||s.endMin<=s.startMin?'次日 ':'')+minToHHmm(s.endMin)).join(' / ');}
  private openDay(day: number): void {if(this.loading||this.failed||this.busy)return;this.selected=day;this.dayOpen=true;this.copyOpen=false;this.sheetVisible=true;}
  private acceptDay(day: RosterDay): void {this.days=this.days.map((d: RosterDay): RosterDay => d.epochDay===day.epochDay?rosterSnapshot(day):d);this.dirty=true;this.feedback='';this.warning=false;}
  private async save(): Promise<void> {
    if(this.busy||this.loading||this.failed)return;this.busy=true;
    const owner=this.owner,week=this.week;
    const result=await WeeklyRosterService.saveDays(owner,this.days,this.warning);this.busy=false;
    if(this.owner!==owner||this.week!==week)return;
    this.feedback=result.message;this.warning=result.warning;
    if(result.changed){this.dirty=false;appToast(result.ok?'已保存这一周':result.message);}
  }
  private prepareCopy(): void {
    if(this.dirty){appToast('请先保存本周，再复制到其他周');return;}
    this.repeat=false;this.targets=[this.week+7];this.repeatFrom=this.week+7;this.repeatTo=this.week+28;
    this.strategy='KEEP';this.feedback='';this.warning=false;this.pendingCopy=[];this.copyOpen=true;this.dayOpen=false;this.sheetVisible=true;
  }
  private selectTarget(day: number): void {this.targets=this.targets.indexOf(day)>=0?this.targets.filter((d: number): boolean => d!==day):this.targets.concat([day]);this.warning=false;this.feedback='';}
  private targetChoices(): number[] {
    const options=this.targets.concat([this.week+7,this.week+14,this.week+21]);
    return Array.from(new Set<number>(options)).sort((a: number,b: number): number => a-b);
  }
  private pickTarget(): void {
    const parts=DateLabel.ymd(this.week+7);
    this.getUIContext().showDatePickerDialog({selected:new Date(parts.y,parts.m-1,parts.d),onDateAccept:(value: Date) => {
      if(!this.copyOpen||this.busy)return;
      const date=weekMonday(epochDayOf(value.getFullYear(),value.getMonth()+1,value.getDate()));
      if(date===this.week){appToast('请选择其他周');return;}
      if(this.targets.indexOf(date)<0)this.targets=this.targets.concat([date]);
      this.warning=false;this.feedback='';
    }});
  }
  private pickRepeat(end: boolean): void {
    const current=end?this.repeatTo:this.repeatFrom,parts=DateLabel.ymd(current);
    this.getUIContext().showDatePickerDialog({selected:new Date(parts.y,parts.m-1,parts.d),onDateAccept:(value: Date) => {
      if(!this.copyOpen||this.busy)return;const day=weekMonday(epochDayOf(value.getFullYear(),value.getMonth()+1,value.getDate()));
      if(end)this.repeatTo=day;else this.repeatFrom=day;this.feedback='';this.warning=false;
    }});
  }
  private async copy(): Promise<void> {
    if(this.busy)return;this.busy=true;
    const owner=this.owner;
    try{
      const targets: number[]=this.repeat?[]:this.targets.slice();
      if(this.repeat){if(this.repeatTo<this.repeatFrom||this.repeatTo-this.repeatFrom>357)throw new Error('结束周不能早于开始周，一次最多重复一年');
        for(let d=this.repeatFrom;d<=this.repeatTo;d+=7)if(d!==this.week)targets.push(d);}
      if(targets.length===0)throw new Error('请选择至少一个目标周');
      const ordered=targets.slice().sort((a: number,b: number): number => a-b);
      const first=ordered[0],last=ordered[ordered.length-1];
      if(last-first>357)throw new Error('目标周的跨度不能超过一年，请分次复制');
      if(!this.warning){const existing=await WeeklyRosterService.loadDays(owner,first,last-first+7);
        if(this.owner!==owner)return;
        this.pendingCopy=copyRosterWeek(this.days,existing,targets,this.strategy);}
      if(this.pendingCopy.length===0){this.feedback='目标日期均已保留，没有需要复制的安排';this.warning=false;this.busy=false;return;}
      const result=await WeeklyRosterService.saveDays(owner,this.pendingCopy,this.warning);
      if(this.owner!==owner)return;
      this.feedback=result.message;this.warning=result.warning;
      if(result.changed){this.closeSheet();this.week=first;this.selected=first;appToast(result.ok?'已复制并保存所选周':result.message);await this.load();}
    }catch(e){this.feedback=(e as Error).message;this.warning=false;}
    finally{this.busy=false;}
  }
  @Builder
  editor() {DayShiftSheet({owner:this.owner,epochDay:this.selected,draft:this.dayOf(this.selected),commitImmediately:false,
    onDraft:(day: RosterDay) => this.acceptDay(day),onClose:() => this.closeSheet()})}
  @Builder
  sheetContent() { if(this.dayOpen){this.editor()}else{this.copySheet()} }
  @Builder
  copySheet() {
    Scroll() {
      Column({space:14}) {
        Row(){Text('复制 / 重复班表').fontSize(22).fontWeight(FontWeight.Bold).layoutWeight(1)
          Button('关闭').height(40).fontSize(13).backgroundColor(DesignTokens.fillWeak).fontColor(DesignTokens.textPrimary)
            .enabled(!this.busy).onClick(() => this.closeSheet())}.width('100%')
        Text('样本：'+DateLabel.md(this.week)+'—'+DateLabel.md(this.week+6)+'，仅复制工作与休息')
          .fontSize(12).fontColor(DesignTokens.textSecondary)
        Row({space:8}) {
          Button('复制到其他周').layoutWeight(1).height(44).fontSize(13).fontColor(DesignTokens.textPrimary)
            .backgroundColor(!this.repeat?DesignTokens.shareSelectedBg:DesignTokens.fillWeak)
            .onClick(() => {this.repeat=false;this.warning=false;this.feedback='';})
          Button('按周重复').layoutWeight(1).height(44).fontSize(13).fontColor(DesignTokens.textPrimary)
            .backgroundColor(this.repeat?DesignTokens.shareSelectedBg:DesignTokens.fillWeak)
            .onClick(() => {this.repeat=true;this.warning=false;this.feedback='';})
        }.width('100%').enabled(!this.busy)
        if(this.repeat) {
          Button('开始周：'+DateLabel.md(this.repeatFrom)).width('100%').height(44).backgroundColor(DesignTokens.fillWeakest)
            .fontColor(DesignTokens.textPrimary).onClick(() => this.pickRepeat(false))
          Button('结束周：'+DateLabel.md(this.repeatTo)).width('100%').height(44).backgroundColor(DesignTokens.fillWeakest)
            .fontColor(DesignTokens.textPrimary).onClick(() => this.pickRepeat(true))
          Text('按整周重复，包含结束周。').fontSize(11).fontColor(DesignTokens.textSecondary)
        }else {
          ForEach(this.targetChoices(),(date: number) => {
            Button((this.targets.indexOf(date)>=0?'✓  ':'')+DateLabel.md(date)+'—'+DateLabel.md(date+6))
              .width('100%').height(44).fontColor(DesignTokens.textPrimary)
              .backgroundColor(this.targets.indexOf(date)>=0?DesignTokens.shareSelectedBg:DesignTokens.fillWeakest)
              .enabled(!this.busy).onClick(() => this.selectTarget(date))
          },(date: number): string => ''+date)
          Button('＋ 选择其他周').height(44).width('100%').fontColor(DesignTokens.primary).backgroundColor(Color.Transparent)
            .enabled(!this.busy).onClick(() => this.pickTarget())
        }
        Text('目标日期已有工作安排时').fontSize(12).fontColor(DesignTokens.textSecondary)
        Row({space:6}) {
          ForEach(['KEEP','REPLACE','MERGE'],(value: string,index: number) => {
            Button(['保留原有','替换原有','合并班次'][index]).layoutWeight(1).height(44).fontSize(12)
              .padding({left:5,right:5}).fontColor(DesignTokens.textPrimary)
              .backgroundColor(this.strategy===value?DesignTokens.shareSelectedBg:DesignTokens.fillWeak)
              .enabled(!this.busy).onClick(() => {this.strategy=value;this.feedback='';this.warning=false;})
          },(value: string): string => value)
        }.width('100%')
        Text('不影响个人安排；班次重叠时不可保存。').fontSize(11).fontColor(DesignTokens.textSecondary)
        if(this.feedback!==''){Text(this.feedback).fontSize(12).fontColor(this.warning?DesignTokens.warn:DesignTokens.danger)}
        Button(this.busy?'保存中…':this.warning?'确认仍然保存':this.repeat?'确认重复':'确认复制').width('100%').height(46)
          .backgroundColor(DesignTokens.primary).enabled(!this.busy).onClick(() => this.copy())
      }.width('100%').alignItems(HorizontalAlign.Start).padding({left:20,right:20,top:22,bottom:24})
    }.width('100%').height(LayoutPolicy.wrapContent).flexShrink(1).scrollBar(BarState.Off).backgroundColor(DesignTokens.card)
  }
  build() {
    Column({space:12}) {
      WeekNavigator({ weekStart: this.week, onPrevious: () => this.changeWeek(this.week-7),
        onNext: () => this.changeWeek(this.week+7), onCurrent: () => this.changeWeek(todayEpochDay()) })
      Row({space:4}) {
        ForEach([0,1,2,3,4,5,6],(i: number) => {
          Column({space:5}) {
            Text(['一','二','三','四','五','六','日'][i]).fontSize(11).fontColor(DesignTokens.textSecondary)
            Text(''+DateLabel.ymd(this.week+i).d).fontSize(18).fontWeight(this.selected===this.week+i?FontWeight.Bold:FontWeight.Normal)
              .fontColor(this.selected===this.week+i?DesignTokens.primary:DesignTokens.textPrimary)
            Circle().width(4).height(4).fill(this.dayOf(this.week+i).status==='WORK'?DesignTokens.primary:this.dayOf(this.week+i).status==='REST'?DesignTokens.planAccent:DesignTokens.textDisabled)
          }.layoutWeight(1).padding({top:10,bottom:9}).borderRadius(16)
            .backgroundColor(this.selected===this.week+i?DesignTokens.card:Color.Transparent)
            .clickEffect(DesignTokens.tapChip())
            .onClick(() => this.openDay(this.week+i))
        },(i: number): string => this.week+'-'+i)
      }.width('100%')
      if(this.loading){Text('正在读取这一周…').fontSize(13).fontColor(DesignTokens.textSecondary)}
      else if(this.failed){Button('重试读取').onClick(() => this.load())}
      else{
        Column() {
          ForEach(this.days,(day: RosterDay) => {
            Row({space:12}) {
              Column({space:3}) {
                Text('周'+['日','一','二','三','四','五','六'][new Date(day.epochDay*86400000).getUTCDay()]).fontSize(10)
                Text(''+DateLabel.ymd(day.epochDay).d).fontSize(20).fontWeight(FontWeight.Medium)
              }.width(40).height(48).justifyContent(FlexAlign.Center).borderRadius(12)
                .backgroundColor(day.epochDay===this.selected?DesignTokens.shareSelectedBg:DesignTokens.fillWeak)
              Column({space:6}) {
                if(day.entries.length===0){Text(day.status==='REST'?'休息':'未安排').fontSize(13)
                  .fontColor(day.status==='REST'?DesignTokens.planAccent:DesignTokens.textTertiary)}
                ForEach(day.entries,(st: ShiftType) => {
                  Row({space:6}) {
                    Circle().width(5).height(5).fill(st.color)
                    Column({space:2}) {
                      Text(st.name).fontSize(13).fontWeight(FontWeight.Medium).fontColor(DesignTokens.textPrimary)
                      Text(this.time(st)).fontSize(11).fontColor(DesignTokens.textSecondary)
                    }.alignItems(HorizontalAlign.Start)
                  }
                },(st: ShiftType): string => JSON.stringify(st))
              }.layoutWeight(1).alignItems(HorizontalAlign.Start)
              Text('›').fontSize(21).fontColor(DesignTokens.textDisabled)
            }.width('100%').padding({top:12,bottom:12}).constraintSize({minHeight:72})
              .onClick(() => this.openDay(day.epochDay))
            if(day.epochDay<this.week+6){Divider().color(DesignTokens.divider)}
          },(day: RosterDay): string => day.epochDay+'|'+JSON.stringify(day))
        }.width('100%').padding({left:16,right:16}).borderRadius(24).backgroundColor(DesignTokens.card)
        Text(this.legacy?'历史循环保留，仅替换已编辑日期；新班表不自动延长。':'未安排不占用工作时间，作息和其他日程照常计算。')
          .fontSize(11).fontColor(DesignTokens.textSecondary).width('100%')
        if(this.feedback!==''&&!this.copyOpen){Text(this.feedback).fontSize(12).fontColor(this.warning?DesignTokens.warn:DesignTokens.danger)}
        Row({space:10}) {
          Button('复制 / 重复').layoutWeight(1).height(46).fontSize(13).backgroundColor(DesignTokens.fillWeak).fontColor(DesignTokens.textPrimary)
            .enabled(!this.busy).onClick(() => this.prepareCopy())
          Button(this.busy?'保存中…':this.warning?'仍然保存':'保存本周').layoutWeight(1).height(46).fontSize(13)
            .backgroundColor(DesignTokens.primary).enabled(!this.busy).onClick(() => this.save())
        }.width('100%')
      }
    }.width('100%').alignItems(HorizontalAlign.Start)
      .bindSheet($$this.sheetVisible,this.sheetContent(),{height:SheetSize.FIT_CONTENT,detents:[SheetSize.FIT_CONTENT],dragBar:false,showClose:false,
        preferType:SheetType.BOTTOM,backgroundColor:DesignTokens.card,maskColor:DesignTokens.scrim,
        onWillDismiss:(action: DismissSheetAction) => {if(!this.busy){action.dismiss();this.closeSheet();}}})
  }
}
