import { ShiftSegment, minToHHmm } from 'domain';
import { DesignTokens } from '../theme/DesignTokens';

@Component
export struct TimeSegmentsEditor {
  @Prop segments: ShiftSegment[] = [];
  @Prop editable: boolean = true;
  @Prop allowMultiple: boolean = true;
  onChange: (segments: ShiftSegment[]) => void = () => {};
  private mounted: boolean = false;
  aboutToAppear(): void { this.mounted=true; }
  aboutToDisappear(): void { this.mounted=false; }
  private clone(): ShiftSegment[] { return this.segments.map((s: ShiftSegment): ShiftSegment => ({startMin:s.startMin,endMin:s.endMin,crossDay:s.crossDay})); }
  private pick(index: number,end: boolean): void {
    if(!this.editable)return;
    const segment=this.segments[index];const min=end?segment.endMin:segment.startMin;
    const selected=new Date();selected.setHours(Math.floor(min/60),min%60,0,0);
    this.getUIContext().showTimePickerDialog({selected:selected,useMilitaryTime:true,
      onAccept:(result: TimePickerResult) => {
        if(!this.mounted || !this.editable || result.hour===undefined || result.minute===undefined || index>=this.segments.length)return;
        const next=this.clone();const value=result.hour*60+result.minute;
        if(end)next[index].endMin=value;else next[index].startMin=value;
        next[index].crossDay=next[index].endMin<=next[index].startMin;
        this.onChange(next);
      }});
  }
  build() {
    Column({space:10}) {
      ForEach(this.segments,(segment: ShiftSegment,index: number) => {
        Column({space:8}) {
          Row({space:8}) {
            Button(minToHHmm(segment.startMin)).layoutWeight(1).height(44)
              .backgroundColor(DesignTokens.card).fontColor(DesignTokens.textPrimary).stateEffect(false)
              .enabled(this.editable).accessibilityText('时段'+(index+1)+'开始时间').onClick(() => this.pick(index,false))
            Text('—').fontColor(DesignTokens.textSecondary)
            Button(minToHHmm(segment.endMin)).layoutWeight(1).height(44)
              .backgroundColor(DesignTokens.card).fontColor(DesignTokens.textPrimary).stateEffect(false)
              .enabled(this.editable).accessibilityText('时段'+(index+1)+'结束时间').onClick(() => this.pick(index,true))
            if(this.segments.length>1) {
              Button('移除').height(44).fontSize(12).backgroundColor(Color.Transparent).fontColor(DesignTokens.textSecondary)
                .enabled(this.editable).onClick(() => this.onChange(this.clone().filter((_s: ShiftSegment,i: number): boolean => i!==index)))
            }
          }.width('100%')
          Row() {
            Button(segment.crossDay||segment.endMin<=segment.startMin?'次日结束 ✓':'当天结束').fontSize(12).height(34)
              .backgroundColor(segment.crossDay?DesignTokens.shareSelectedBg:DesignTokens.fillWeak)
              .fontColor(DesignTokens.textSecondary).enabled(this.editable)
              .onClick(() => {const next=this.clone();next[index].crossDay=!segment.crossDay;this.onChange(next);})
            Blank()
            Text('时段 '+(index+1)).fontSize(11).fontColor(DesignTokens.textTertiary)
          }.width('100%')
        }.width('100%').padding(12).borderRadius(18).backgroundColor(DesignTokens.fillWeakest)
      },(segment: ShiftSegment,index: number): string => index+'|'+segment.startMin+'|'+segment.endMin+'|'+segment.crossDay)
      if(this.allowMultiple && this.segments.length<8) {
        Button('＋ 再加一个时段').width('100%').height(44).stateEffect(false)
          .backgroundColor(Color.Transparent).fontColor(DesignTokens.primary).enabled(this.editable)
          .onClick(() => this.onChange(this.clone().concat([{startMin:840,endMin:1080,crossDay:false}])))
      }
    }.width('100%')
  }
}
