import { DesignTokens } from '../theme/DesignTokens';
import { AccessibilityPolicy } from '../accessibility/AccessibilityPolicy';
import { EditorialCard } from './EditorialCard';

/** @Builder 传两个及以上参数时不参与动态渲染（ArkUI 限制），所以整行合成一个对象字面量按引用传。 */
interface BusyLineArg {
  who: string;
  text: string;
  dot: Resource;
}

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
  // 装饰器实参必须是字面量，取值与 SENIOR_MODE_KEY 保持一致。
  @StorageProp('crd_senior_mode') senior: boolean = false;
  /** 两颗胶囊共用一个焦点位：-1 表示没有键盘焦点，0/1 是画焦点环的那一颗。 */
  @State private focusedPill: number = -1;

  @Builder
  busyLine(row: BusyLineArg) {
    Row({ space: DesignTokens.space2 }) {
      Circle()
        .width(DesignTokens.space2)
        .height(DesignTokens.space2)
        .fill(row.dot)
        // 我 / TA 已经在紧邻的文字里，圆点只是颜色分区，不再朗读一遍
        .accessibilityLevel('no')
      Text(row.who)
        .fontSize(DesignTokens.fontCaption)
        .fontColor(DesignTokens.textSecondary)
        .width(40)
      Text(row.text)
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
          .fontFamily(DesignTokens.fontRound)
          .fontWeight(FontWeight.Bolder)
          .fontColor(DesignTokens.textPrimary)
          .layoutWeight(1)
        Text(this.weekdayText)
          .fontSize(DesignTokens.fontCaption)
          .fontColor(DesignTokens.textTertiary)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      this.busyLine({ who: '我', text: this.myText, dot: DesignTokens.busyMine })
      if (this.partnerVisible) {
        this.busyLine({
          who: this.partnerName === '' ? 'TA' : this.partnerName,
          text: this.partnerText,
          dot: DesignTokens.busyPartner
        })
      }

      Text(this.commonText)
        .fontSize(DesignTokens.fontCaption)
        .fontColor(DesignTokens.primary)
        .fontWeight(700)
        .width('100%')
        .padding({
          left: DesignTokens.space3,
          right: DesignTokens.space3,
          top: DesignTokens.space2,
          bottom: DesignTokens.space2
        })
        .borderRadius(DesignTokens.radiusPill)
        .backgroundColor(DesignTokens.primaryBg)
        .margin({ top: DesignTokens.space3 })

      Row({ space: DesignTokens.space2 }) {
        this.actionPill(0, '改班表 / 加课程', '改班表或加课程', false, () => {
          this.onEditSchedule();
        })
        this.actionPill(1, '＋ 计划', '添加计划', true, () => {
          this.onAddPlan();
        })
      }
      .width('100%')
      .margin({ top: DesignTokens.space3 })
    }
  }

  /** 胶囊动作：文字当按钮用时要自己补齐热区、焦点环与可朗读名（原生 Text 不带这些）。 */
  @Builder
  actionPill(idx: number, label: string, readAs: string, primary: boolean, onTap: () => void) {
    Text(label)
      .fontSize(DesignTokens.fontCaption)
      .fontColor(primary ? DesignTokens.heroText : DesignTokens.textSecondary)
      .fontWeight(700)
      .textAlign(TextAlign.Center)
      .padding({ left: DesignTokens.space3, right: DesignTokens.space3 })
      .constraintSize({ minHeight: AccessibilityPolicy.minHit(this.senior) })
      .borderRadius(DesignTokens.radiusPill)
      .backgroundColor(primary ? DesignTokens.primary : DesignTokens.fillWeak)
      // 主操作给一条果冻厚底；次操作是浅底芯片，不需要下沿
      .shadow(primary ? DesignTokens.jelly(DesignTokens.primaryDeep, DesignTokens.jellyDepth) : undefined)
      // 焦点环常驻 2vp 透明边，聚焦时不跳动（与首页答案行同一口径）。
      .border({
        width: 2,
        color: this.focusedPill === idx ? DesignTokens.focusRing : Color.Transparent,
        radius: DesignTokens.radiusPill
      })
      .layoutWeight(1)
      .focusable(true)
      .accessibilityText(readAs)
      .onFocus(() => {
        this.focusedPill = idx;
      })
      .onBlur(() => {
        this.focusedPill = -1;
      })
      .clickEffect(DesignTokens.tapChip())
      .onClick(onTap)
  }
}
