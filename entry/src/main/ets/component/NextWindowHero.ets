import { MIN_PER_DAY } from 'domain';
import { DateLabel } from 'commons';
import { ExperienceMode } from 'feature';
import { DesignTokens } from '../theme/DesignTokens';
import { EditorialCard } from './EditorialCard';

/** Hero 三种形态：有下一段共同时间 / 缺对方数据 / 视界内没有窗口。 */
export enum HeroVariant {
  WINDOW = 'WINDOW',
  NEED_PARTNER = 'NEED_PARTNER',
  NO_WINDOW = 'NO_WINDOW'
}

/**
 * 首页主视觉：一屏里只有一张粉渐变 Hero，用来放"下一段共同时间"这一个最重要的结论。
 * 窗口文案（时长/起止/分类）全部取自读模型，页面不自行拼业务结论。
 */
@Component
export struct NextWindowHero {
  @Prop variant: HeroVariant = HeroVariant.NO_WINDOW;
  @Prop experience: ExperienceMode = ExperienceMode.SOLO;
  @Prop todayEpoch: number = 0;
  @Prop winStart: number = 0;
  @Prop winEnd: number = 0;
  @Prop winDuration: number = 0;
  /** 分类摘要（如"旅行窗口 · 完整同休日"），由查询服务给出，页面不再映射标签。 */
  @Prop winSubtitle: string = '';
  onTapHero: () => void = () => {};
  @StorageProp('crd_reduce_motion') reduceMotion: boolean = false;
  @State private beat: number = 1;

  /** 心跳起来一次就交给框架循环；开启"减少动效"时压根不挂上。 */
  private startBeat(): void {
    if (this.reduceMotion) {
      return;
    }
    this.getUIContext().animateTo({
      duration: DesignTokens.beatMs,
      iterations: -1,
      curve: Curve.EaseInOut,
      playMode: PlayMode.Alternate
    }, () => {
      this.beat = DesignTokens.beatScale;
    });
  }

  /** 距今天数口语化：0=就在今天，1=明天，其余报天数（D-17 定稿：不写「就在明天」）。 */
  private daysWord(): string {
    const days = Math.floor(this.winStart / MIN_PER_DAY) - this.todayEpoch;
    if (days <= 0) {
      return '就在今天';
    }
    if (days === 1) {
      return '明天';
    }
    return days + ' 天后';
  }

  private needTitle(): string {
    return this.experience === ExperienceMode.SOLO ? '还没有录入伴侣' : '还不知道 TA 的日程';
  }

  private needBody(): string {
    if (this.experience === ExperienceMode.SOLO) {
      return '在「我的」里代录 TA 的作息与班表，这里就会出现你们的第一个共同时间。';
    }
    return '今天的共同时间要等 TA 的数据；重新同步或补充代录后再看。';
  }

  build() {
    if (this.variant === HeroVariant.NO_WINDOW) {
      // 没有窗口时不占 Hero：纸面卡片说明事实与下一步，不假装"很快会有"
      EditorialCard({ hero: false, cutTopLeft: true, tappable: false }) {
        Text('近期没有可安排的共同时间')
          .fontSize(DesignTokens.fontBody)
          .fontFamily(DesignTokens.fontRound)
          .fontColor(DesignTokens.textSecondary)
        Text('双方班表可能完全错开。检查班次与作息参数，或到共同时间页放宽筛选。')
          .fontSize(DesignTokens.fontCaption)
          .fontColor(DesignTokens.textTertiary)
          .lineHeight(DesignTokens.space5)
          .margin({ top: DesignTokens.space2 })
      }
    } else {
      EditorialCard({
        hero: true,
        cutTopLeft: true,
        tappable: true,
        glass: true,
        onTapCard: () => this.onTapHero()
      }) {
        if (this.variant === HeroVariant.WINDOW) {
          Row() {
            Text(this.daysWord() + ' · ' + DateLabel.mdw(Math.floor(this.winStart / MIN_PER_DAY)))
              .fontSize(DesignTokens.fontCaption)
              .fontColor(DesignTokens.heroText)
              .opacity(0.9)
              .layoutWeight(1)
            Text('去计划')
              .fontSize(DesignTokens.fontCaption)
              .fontColor(DesignTokens.heroText)
              .fontWeight(600)
            Text('↗')
              .fontSize(DesignTokens.fontCaption)
              .fontColor(DesignTokens.heroText)
              .textAlign(TextAlign.Center)
              .width(DesignTokens.space5)
              .height(DesignTokens.space5)
              .borderRadius(DesignTokens.radiusPill)
              .backgroundColor(DesignTokens.heroGlow)
              .margin({ left: DesignTokens.space2 })
              // 箭头只作视觉提示，"去计划"已经在旁边的文字里
              .accessibilityLevel('no')
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)

          Row({ space: DesignTokens.space2 }) {
            // 原型 .hb：时长前一颗白心，是全 App 唯一的常驻动效，且尊重"减少动效"
            Image($r('app.media.heart_white'))
              .width(17)
              .height(17)
              .alignSelf(ItemAlign.Center)
              .scale({ x: this.beat, y: this.beat })
              .onAppear(() => this.startBeat())
              .accessibilityLevel('no')
            Text(DateLabel.duration(this.winDuration))
              .fontSize(DesignTokens.fontDisplay)
              .fontFamily(DesignTokens.fontRound)
              .fontWeight(FontWeight.Bolder)
              .fontColor(DesignTokens.heroText)
          }
          .alignItems(VerticalAlign.Center)
          .margin({ top: DesignTokens.space2 })
          Text(DateLabel.endLabel(this.winStart, this.winEnd))
            .fontSize(DesignTokens.fontCaption)
            .fontColor(DesignTokens.heroText)
            .opacity(0.95)
            .margin({ top: DesignTokens.space1 })
          if (this.winSubtitle !== '') {
            Text(this.winSubtitle)
              .fontSize(DesignTokens.fontCaption)
              .fontColor(DesignTokens.heroText)
              .opacity(0.8)
              .margin({ top: DesignTokens.space3 })
          }
        } else {
          Text(this.needTitle())
            .fontSize(DesignTokens.fontTitle)
            .fontFamily(DesignTokens.fontRound)
            .fontWeight(FontWeight.Bolder)
            .fontColor(DesignTokens.heroText)
          Text(this.needBody())
            .fontSize(DesignTokens.fontCaption)
            .fontColor(DesignTokens.heroText)
            .opacity(0.92)
            .lineHeight(DesignTokens.space5)
            .margin({ top: DesignTokens.space2 })
          Text(this.experience === ExperienceMode.SOLO ? '去添加 ›' : '去看看 ›')
            .fontSize(DesignTokens.fontCaption)
            .fontColor(DesignTokens.heroText)
            .fontWeight(600)
            // 朗读里不念尾随的箭头符号
            .accessibilityText(this.experience === ExperienceMode.SOLO ? '去添加伴侣' : '去看看')
            .padding({
              left: DesignTokens.space3,
              right: DesignTokens.space3,
              top: DesignTokens.space1,
              bottom: DesignTokens.space1
            })
            .borderRadius(DesignTokens.radiusPill)
            .backgroundColor(DesignTokens.heroGlow)
            .margin({ top: DesignTokens.space3 })
        }
      }
    }
  }
}
