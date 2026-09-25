import { MIN_PER_DAY } from 'domain';
import { DateLabel } from 'commons';
import { DesignTokens } from '../theme/DesignTokens';
import { EditorialCard } from './EditorialCard';
import { displayTagLabel, tagColor } from '../util/WindowTagUtil';

/** 时长轨道的满刻度（分钟）：36 小时以上一律画满，避免长窗口把轨道比例压平。 */
const TRACK_FULL_SCALE_MIN = 36 * 60;

/**
 * 共同时间列表行：一张卡只回答"哪天、多久、几点到几点、值不值得安排"。
 * 文案与时长全部来自读模型（含压缩后的展示标签），卡片不再堆全部领域标签；
 * 点击交由父页打开窗口详情（创建计划入口），卡片自身不查数据。
 */
@Component
export struct WindowCard {
  @Prop winStart: number = 0;
  @Prop winEnd: number = 0;
  @Prop winDuration: number = 0;
  /** 展示标签（最多三档），'|' 连接；空串表示这一行没有可展示的标签。 */
  @Prop displayTags: string = '';
  @Prop todayEpoch: number = 0;
  @Prop cutTopLeft: boolean = true;
  // 装饰器实参必须是字面量，取值与 SENIOR_MODE_KEY 保持一致。
  @StorageProp('crd_senior_mode') senior: boolean = false;
  onTapCard: () => void = () => {};

  private startDay(): number {
    return Math.floor(this.winStart / MIN_PER_DAY);
  }

  /** 距今天数口语化：已经开始的说进行中，其余说今天/明天/N 天后。 */
  private daysWord(): string {
    const days = this.startDay() - this.todayEpoch;
    if (days < 0) {
      return '进行中';
    }
    if (days === 0) {
      return '今天';
    }
    if (days === 1) {
      return '明天';
    }
    return days + ' 天后';
  }

  private trackPct(): string {
    const pct = Math.min(100, this.winDuration / TRACK_FULL_SCALE_MIN * 100);
    return pct.toFixed(1) + '%';
  }

  private tagList(): string[] {
    if (this.displayTags === '') {
      return [];
    }
    return this.displayTags.split('|');
  }

  build() {
    EditorialCard({
      hero: false,
      cutTopLeft: this.cutTopLeft,
      tappable: true,
      onTapCard: () => this.onTapCard()
    }) {
      Row() {
        Text(DateLabel.mdw(this.startDay()))
          .fontSize(DesignTokens.fontBody(this.senior))
          .fontFamily(DesignTokens.fontSerif)
          .fontWeight(FontWeight.Medium)
          .fontColor(DesignTokens.textPrimary)
          .letterSpacing(-0.4)
        Text(this.daysWord())
          .fontSize(DesignTokens.fontCaption(this.senior))
          .fontColor(DesignTokens.textTertiary)
          .margin({ left: DesignTokens.space2 })
          .layoutWeight(1)
        Text(DateLabel.duration(this.winDuration))
          .fontSize(DesignTokens.fontBody(this.senior))
          .fontFamily(DesignTokens.fontSerif)
          .fontWeight(FontWeight.Medium)
          .fontColor(DesignTokens.primary)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Text(DateLabel.endLabel(this.winStart, this.winEnd))
        .fontSize(DesignTokens.fontCaption(this.senior))
        .fontColor(DesignTokens.textSecondary)
        .margin({ top: DesignTokens.space1 })

      // 时长轨道：一眼分出"半小时碎片"和"能安排一整天"
      Stack({ alignContent: Alignment.Start }) {
        Row()
          .width('100%')
          .height(4)
          .borderRadius(DesignTokens.radiusPill)
          .backgroundColor(DesignTokens.fillWeak)
        Row()
          .width(this.trackPct())
          .height(4)
          .borderRadius(DesignTokens.radiusPill)
          .backgroundColor(DesignTokens.primary)
      }
      .width('100%')
      .margin({ top: DesignTokens.space3 })
      // 纯视觉的时长对比条：朗读里时长已经由上面的文字给出，这条不再读一遍
      .accessibilityLevel('no')

      if (this.tagList().length > 0) {
        Row({ space: DesignTokens.space2 }) {
          ForEach(this.tagList(), (t: string) => {
            Text(displayTagLabel(t))
              .fontSize(DesignTokens.fontCaption(this.senior))
              .fontColor(DesignTokens.heroText)
              .padding({
                left: DesignTokens.space2,
                right: DesignTokens.space2,
                top: 2,
                bottom: 2
              })
              .borderRadius(DesignTokens.radiusCardCut)
              .backgroundColor(tagColor(t))
          }, (t: string) => t)
        }
        .width('100%')
        .margin({ top: DesignTokens.space3 })
      }
    }
  }
}
