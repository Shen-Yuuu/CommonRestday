import { router } from '@kit.ArkUI';
import { OWNER_ME } from 'domain';
import { ownerFromParams, ownerParam } from '../model/RouteParams';
import { WeeklyRosterView } from '../component/WeeklyRosterView';
import { DesignTokens } from '../theme/DesignTokens';
import { askConfirm } from '../util/AppConfirm';
import { appToast } from '../util/AppToast';
import { AccessibilityPolicy } from '../accessibility/AccessibilityPolicy';

@Entry
@Component
struct CycleEditor {
  @State owner: string = OWNER_ME;
  @State private dirty: boolean = false;
  @State private busy: boolean = false;
  @StorageProp('crd_senior_mode') senior: boolean = false;
  aboutToAppear(): void { this.owner = ownerFromParams(router.getParams()); }
  private leave(): void {
    if (this.busy) { appToast('正在保存，请稍候'); return; }
    if (this.dirty) askConfirm(this.getUIContext(), { message: '本周还有未保存的修改。放弃草稿并返回？',
      confirmText: '放弃草稿', onConfirm: () => { if (!this.busy) { this.dirty=false; router.back(); } } });
    else router.back();
  }
  onBackPress(): boolean { if (this.dirty || this.busy) { this.leave(); return true; } return false; }
  build() {
    Column() {
      Stack({ alignContent: Alignment.Center }) {
        Text(this.owner === OWNER_ME ? '周班表' : 'TA 的周班表')
          .fontSize(17).fontWeight(FontWeight.Bold).fontColor(DesignTokens.textPrimary)
          .hitTestBehavior(HitTestMode.None)
        Row() {
          Row({ space: 2 }) {
            SymbolGlyph($r('sys.symbol.chevron_left')).fontSize(16).fontColor([DesignTokens.primary])
              .accessibilityLevel('no')
            Text('返回').fontSize(15).fontColor(DesignTokens.textAccent)
          }.constraintSize({ minHeight: AccessibilityPolicy.minHit(this.senior) })
            .focusable(true).accessibilityGroup(true).accessibilityText('返回上一页')
            .onClick(() => this.leave())
          Blank()
          Text('常用班次').fontSize(14).fontColor(DesignTokens.textAccent)
            .constraintSize({ minHeight: AccessibilityPolicy.minHit(this.senior) })
            .focusable(true).accessibilityText('管理常用班次').enabled(!this.busy)
            .onClick(() => router.pushUrl({ url: 'pages/ScheduleEditor', params: ownerParam(this.owner) }))
        }.width('100%')
      }.width('100%').padding(12)
      Scroll() {
        WeeklyRosterView({ owner: this.owner, onDirty: (dirty: boolean) => { this.dirty=dirty; },
          onBusy: (busy: boolean) => { this.busy=busy; } })
      }.layoutWeight(1).width('100%').padding({ left: 20, right: 20, bottom: 24 })
        .align(Alignment.Top).scrollBar(BarState.Off)
    }.width('100%').height('100%')
      .linearGradient(DesignTokens.pageGradient())
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}
