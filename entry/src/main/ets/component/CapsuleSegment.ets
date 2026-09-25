import { CapsuleSegmentButtonV2, ColorMetrics, LengthMetrics, SegmentButtonV2Items } from '@kit.ArkUI';
import { DesignTokens } from '../theme/DesignTokens';

/**
 * 胶囊滑动选项卡：共同页的「时间窗口 / 共同计划」与日程录入页的「周历 / 日程管理」共用一份外观。
 * 抽出来不是省事：两处各写一遍令牌，改一处就会让两个页面开始长得不一样；
 * 那四枚 ColorMetrics.resourceColor 告警也会跟着复制一份（告警基线按全仓总数计）。
 */
@Component
export struct CapsuleSegment {
  items: SegmentButtonV2Items = new SegmentButtonV2Items([]);
  /** 当前选中项下标：由父页持有，本页只读它、不改它。 */
  @Prop selectedIndex: number = 0;
  /** 用户点了哪一项：父页拿到下标后自己换算成本页的状态口径。 */
  onPick: (idx: number) => void = () => {
  };

  build() {
    CapsuleSegmentButtonV2({
      items: this.items,
      selectedIndex: this.selectedIndex,
      $selectedIndex: (idx: number) => {
        this.onPick(idx);
      },
      itemFontSize: LengthMetrics.fp(14),
      itemFontColor: ColorMetrics.resourceColor(DesignTokens.textSecondary),
      // 7 分甜把选中态从"粉底白字"翻成"白底粉字"：胶囊是浮在背板上的一颗糖，不再是一块色块。
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
  }
}
