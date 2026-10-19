import { ScrollHeaderMotion } from 'commons';
import { DesignTokens } from '../theme/DesignTokens';

/** @Track 精确到 offset 属性；正文只传对象，不读取偏移。 */
@Observed
export class ScrollHeaderState {
  @Track offset: number = 0;

  update(offset: number): void {
    const next = ScrollHeaderMotion.visualOffset(offset);
    if (next !== this.offset) {
      this.offset = next;
    }
  }
}

/** 渐隐只画在滚动内容边缘，不能吃掉卡片和日期按钮的点击。 */
@Component
export struct HeaderFadeEdge {
  fadeHeight: number = 24;
  @ObjectLink visual: ScrollHeaderState;

  build() {
    Row()
      .width('100%')
      .height(this.fadeHeight)
      .linearGradient({ angle: 180, colors: [[DesignTokens.pageGradTop, 0], [DesignTokens.pageGradClear, 1]] })
      .opacity(ScrollHeaderMotion.edgeOpacity(this.visual.offset))
      .hitTestBehavior(HitTestMode.None)
      .accessibilityLevel('no')
  }
}

/** 视口不观察偏移，避免滚动时刷新 content Builder 和其下的滚动组件。 */
@Component
export struct FadingScrollViewport {
  fadeHeight: number = 24;
  @ObjectLink visual: ScrollHeaderState;
  @BuilderParam content: () => void = this.placeholder;

  @Builder
  placeholder() {}

  build() {
    Stack({ alignContent: Alignment.Top }) {
      this.content()
      HeaderFadeEdge({ fadeHeight: this.fadeHeight, visual: this.visual })
        .hitTestBehavior(HitTestMode.None)
        .accessibilityLevel('no')
    }
    .width('100%').height('100%')
    .clip(true)
  }
}

@Component
export struct FadingHeaderSurface {
  @BuilderParam content: () => void = this.placeholder;

  @Builder
  placeholder() {}

  build() {
    Column() {
      this.content()
    }
    .width('100%')
    .backgroundColor(DesignTokens.pageGradTop)
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP])
    .hitTestBehavior(HitTestMode.Transparent)
  }
}

/** 标题自然占位，滚动只改绘制比例与透明度，不反推正文布局。 */
@Component
export struct StickyPageHeader {
  @Prop title: string = '';
  @Prop subtitle: string = '';
  @ObjectLink visual: ScrollHeaderState;
  @Prop horizontalPadding: number = 20;
  @Prop maxContentWidth: Length = '100%';
  @StorageProp('crd_reduce_motion') reduceMotion: boolean = false;
  @BuilderParam trailing: () => void = this.placeholder;

  @Builder
  placeholder() {}

  private titleScale(): number {
    return ScrollHeaderMotion.titleScale(this.visual.offset, this.reduceMotion);
  }

  build() {
    FadingHeaderSurface() {
      Row() {
        Column({ space: DesignTokens.space1 }) {
          Text(this.title)
            .fontSize(DesignTokens.fontDisplay)
            .fontFamily(DesignTokens.fontRound)
            .fontWeight(FontWeight.Bolder)
            .fontColor(DesignTokens.textPrimary)
            .scale({ x: this.titleScale(), y: this.titleScale(), centerX: 0, centerY: '50%' })
          Text(this.subtitle)
            .fontSize(DesignTokens.fontCaption)
            .fontColor(DesignTokens.textSecondary)
            .opacity(ScrollHeaderMotion.subtitleOpacity(this.visual.offset, this.reduceMotion))
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        this.trailing()
      }
      .width('100%')
      .constraintSize({ maxWidth: this.maxContentWidth })
      .alignItems(VerticalAlign.Center)
      .padding({ left: this.horizontalPadding, right: this.horizontalPadding,
        top: DesignTokens.space4, bottom: 0 })
    }
  }
}

/** 日期保持固定占位，与标题同进度缩放；不让正文订阅滚动偏移。 */
@Component
export struct HeaderDateBadge {
  @Prop day: string = '';
  @Prop month: string = '';
  @Prop spokenDate: string = '';
  @ObjectLink visual: ScrollHeaderState;
  @StorageProp('crd_reduce_motion') reduceMotion: boolean = false;

  private badgeScale(): number {
    return ScrollHeaderMotion.titleScale(this.visual.offset, this.reduceMotion);
  }

  build() {
    Column() {
      Text(this.day).fontSize(DesignTokens.fontCaption).fontFamily(DesignTokens.fontRound)
        .fontWeight(800).fontColor(DesignTokens.textAccent)
      Text(this.month).fontSize(DesignTokens.fontCaption).fontFamily(DesignTokens.fontRound)
        .fontWeight(800).fontColor(DesignTokens.textAccent).opacity(0.72)
    }.width(48).height(48).justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
      .borderRadius(DesignTokens.radiusHeroCut).backgroundColor(DesignTokens.card)
      .shadow(DesignTokens.floatShadow()).margin({ left: DesignTokens.space3 })
      .scale({ x: this.badgeScale(), y: this.badgeScale(), centerX: '100%', centerY: '50%' })
      .accessibilityGroup(true).accessibilityText(this.spokenDate)
  }
}
