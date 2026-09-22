import { DesignTokens } from '../theme/DesignTokens';
import { EditorialCard } from './EditorialCard';

/**
 * 今日双方概览：我 / TA / 共同三行忙碌与空闲摘要，加两个下一步动作。
 * 三行文本全部来自读模型（含对方隐私等级造成的粗粒度表述），页面不重算、不改写。
 */
@Component
export struct TodayOverview {
  @Prop myText: string = '';
  @Prop partnerText: string = '';
  @Prop commonText: string = '';
  /** 单人形态不显示 TA 行（此时 partnerText 是"未知"，展示出来只会造成误解）。 */
  @Prop partnerVisible: boolean = false;
  @Prop partnerName: string = '';
  @Prop weekdayText: string = '';
  onEditSchedule: () => void = () => {};
  onAddPlan: () => void = () => {};

  @Builder
  busyLine(who: string, text: string, dot: Resource) {
    Row({ space: DesignTokens.space2 }) {
      Circle()
        .width(DesignTokens.space2)
        .height(DesignTokens.space2)
        .fill(dot)
      Text(who)
        .fontSize(DesignTokens.fontCaption)
        .fontColor(DesignTokens.textSecondary)
        .width(40)
      Text(text)
        .fontSize(DesignTokens.fontCaption)
        .fontColor(DesignTokens.textPrimary)
        .layoutWeight(1)
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .margin({ top: DesignTokens.space2 })
  }

  build() {
    EditorialCard({ hero: false, cutTopLeft: false, tappable: false }) {
      Row() {
        Text('今天')
          .fontSize(DesignTokens.fontTitle)
          .fontFamily(DesignTokens.fontSerif)
          .fontWeight(FontWeight.Medium)
          .fontColor(DesignTokens.textPrimary)
          .letterSpacing(-0.7)
          .layoutWeight(1)
        Text(this.weekdayText)
          .fontSize(DesignTokens.fontCaption)
          .fontColor(DesignTokens.textTertiary)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      this.busyLine('我', this.myText, DesignTokens.busyMine)
      if (this.partnerVisible) {
        this.busyLine(this.partnerName === '' ? 'TA' : this.partnerName,
          this.partnerText, DesignTokens.busyPartner)
      }

      Text(this.commonText)
        .fontSize(DesignTokens.fontCaption)
        .fontColor(DesignTokens.primary)
        .fontWeight(600)
        .width('100%')
        .padding({
          left: DesignTokens.space3,
          right: DesignTokens.space3,
          top: DesignTokens.space2,
          bottom: DesignTokens.space2
        })
        .borderRadius(DesignTokens.radiusCardCut)
        .backgroundColor(DesignTokens.primaryBg)
        .margin({ top: DesignTokens.space3 })

      Row({ space: DesignTokens.space2 }) {
        Text('改班表 / 加课程')
          .fontSize(DesignTokens.fontCaption)
          .fontColor(DesignTokens.textSecondary)
          .fontWeight(600)
          .textAlign(TextAlign.Center)
          .padding({ left: DesignTokens.space3, right: DesignTokens.space3 })
          .constraintSize({ minHeight: DesignTokens.hitMin })
          .borderRadius(DesignTokens.radiusCardCut)
          .backgroundColor(DesignTokens.fillWeak)
          .layoutWeight(1)
          .onClick(() => {
            this.onEditSchedule();
          })
        Text('＋ 计划')
          .fontSize(DesignTokens.fontCaption)
          .fontColor(DesignTokens.heroText)
          .fontWeight(600)
          .textAlign(TextAlign.Center)
          .padding({ left: DesignTokens.space3, right: DesignTokens.space3 })
          .constraintSize({ minHeight: DesignTokens.hitMin })
          .borderRadius(DesignTokens.radiusCardCut)
          .backgroundColor(DesignTokens.primary)
          .layoutWeight(1)
          .onClick(() => {
            this.onAddPlan();
          })
      }
      .width('100%')
      .margin({ top: DesignTokens.space3 })
    }
  }
}
