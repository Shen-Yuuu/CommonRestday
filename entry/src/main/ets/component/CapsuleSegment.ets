import { CapsuleSegmentButtonV2, ColorMetrics, LengthMetrics, SegmentButtonV2Items } from '@kit.ArkUI';
import { DesignTokens } from '../theme/DesignTokens';

/** 共用的胶囊选项卡。 */
@Component
export struct CapsuleSegment {
  items: SegmentButtonV2Items = new SegmentButtonV2Items([]);
  /** 当前选中项下标：由父页持有，本页只读它、不改它。 */
  @Prop selectedIndex: number = 0;
  @Prop pendingBadge: boolean = false;
  /** 用户点了哪一项：父页拿到下标后自己换算成本页的状态口径。 */
  onPick: (idx: number) => void = () => {
  };

  build() {
    Stack({ alignContent: Alignment.TopEnd }) {
    CapsuleSegmentButtonV2({
      items: this.items,
      selectedIndex: this.selectedIndex,
      $selectedIndex: (idx: number) => {
        this.onPick(idx);
      },
      itemFontSize: LengthMetrics.fp(14),
      itemFontColor: ColorMetrics.resourceColor(DesignTokens.textSecondary),
      itemSelectedFontColor: ColorMetrics.resourceColor(DesignTokens.primary),
      itemSelectedBackgroundColor: ColorMetrics.resourceColor(DesignTokens.card),
      itemFontWeight: FontWeight.Bold,
      itemSelectedFontWeight: FontWeight.Bold,
      itemBorderRadius: LengthMetrics.vp(999),
      buttonBackgroundColor: ColorMetrics.resourceColor(DesignTokens.fillWeak),
      buttonBorderRadius: LengthMetrics.vp(999),
      buttonPadding: LengthMetrics.vp(4)
    })
      .width('100%')
      if (this.pendingBadge) {
        Circle().width(7).height(7).fill(DesignTokens.primary).margin({ top: 6, right: 12 })
          .hitTestBehavior(HitTestMode.None).accessibilityText('有共同计划待确认')
      }
    }.width('100%')
  }
}
