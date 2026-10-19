import { DateLabel } from 'commons';
import { dayOfStart } from 'domain';
import { DesignTokens } from '../theme/DesignTokens';

@Component
export struct PlanDateTicket {
  @Prop start: number = -1;

  build() {
    Column({ space: 2 }) {
      if (this.start >= 0) {
        Text(DateLabel.ymd(dayOfStart(this.start)).m + '月').fontSize(11).fontColor(DesignTokens.planMuted)
          .accessibilityLevel('no')
        Text('' + DateLabel.ymd(dayOfStart(this.start)).d).fontSize(24).fontWeight(FontWeight.Bold)
          .fontColor(DesignTokens.planInk).fontFamily(DesignTokens.fontRound).accessibilityLevel('no')
        Text(DateLabel.weekday(dayOfStart(this.start))).fontSize(11).fontColor(DesignTokens.planMuted)
          .accessibilityLevel('no')
      } else {
        Text('—').fontSize(24).fontColor(DesignTokens.planInk).accessibilityLevel('no')
        Text('未安排').fontSize(11).fontColor(DesignTokens.planMuted).accessibilityLevel('no')
      }
    }.width(60).padding({ top: 6, bottom: 6 }).borderRadius(14)
      .backgroundColor(DesignTokens.planSurface)
  }
}
