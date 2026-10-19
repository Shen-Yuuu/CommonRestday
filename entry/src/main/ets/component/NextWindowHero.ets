import { dayOfStart } from 'domain';
import { DateLabel } from 'commons';
import { ExperienceMode } from 'feature';
import { AnimatorResult } from '@kit.ArkUI';
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
  @Prop refreshCue: number = 0;
  @State private hovered: boolean = false;
  // 装饰器实参必须是字面量，取值与 MOTION_REDUCE_KEY 保持一致。
  @StorageProp('crd_reduce_motion') @Watch('onReduceMotionChanged') reduceMotion: boolean = false;
  @StorageProp('crd_app_foreground') @Watch('onReduceMotionChanged') foreground: boolean = true;
  @StorageProp('crd_root_page_visible') @Watch('onReduceMotionChanged') rootVisible: boolean = true;
  @State private beat: number = 1;
  /** 心跳的驱动器：animateTo 挂上的无限循环停不掉，只有 animator 能被"中途打开减少动效"指挥。 */
  private beatAnim: AnimatorResult | undefined = undefined;
  private beatVisible: boolean = false;

  /**
   * 原型 .hb 那颗白心是全 App 唯一的常驻动效，所以它必须能被当场收住：
   * 系统"减少动效"是用户随时在设置里拨的，而 AccessibilityPolicy 的监听会实时写进 AppStorage，
   * 用 animateTo({ iterations: -1 }) 起的心跳一旦起来就没有取消入口，只能等节点销毁。
   */
  private startBeat(): void {
    if (this.reduceMotion || !this.foreground || !this.rootVisible || !this.beatVisible
      || this.beatAnim !== undefined) {
      return;
    }
    const anim = this.getUIContext().createAnimator({
      duration: DesignTokens.beatMs,
      easing: 'ease-in-out',
      delay: 0,
      fill: 'forwards',
      iterations: -1,
      direction: 'alternate',
      begin: 1,
      end: DesignTokens.beatScale
    });
    anim.onFrame = (value: number) => {
      if (this.beatAnim === anim) { this.beat = value; }
    };
    this.beatAnim = anim;
    anim.play();
  }

  /** 收心跳并把尺寸归回 1：减少动效打开时心要停在原大小，不是停在某一帧上。 */
  private stopBeat(): void {
    const anim = this.beatAnim;
    this.beatAnim = undefined;
    if (anim !== undefined) {
      anim.cancel();
    }
    this.beat = 1;
  }

  onReduceMotionChanged(): void {
    if (this.reduceMotion || !this.foreground || !this.rootVisible || !this.beatVisible) {
      this.stopBeat();
    } else {
      this.startBeat();
    }
  }

  aboutToDisappear(): void {
    this.stopBeat();
  }

  /** 距今天数口语化：0=就在今天，1=明天，其余报天数（D-17 定稿：不写「就在明天」）。 */
  private daysWord(): string {
    const days = dayOfStart(this.winStart) - this.todayEpoch;
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
      return '到「我的」添加伴侣或代录班表。';
    }
    return '同步或补录 TA 的日程后查看。';
  }

  build() {
    if (this.variant === HeroVariant.NO_WINDOW) {
      // 没有窗口时不占 Hero：纸面卡片说明事实与下一步，不假装"很快会有"
      EditorialCard({ hero: false, cutTopLeft: true, tappable: false, refreshCue: this.refreshCue }) {
        Text('近期没有可安排的共同时间')
          .fontSize(DesignTokens.fontBody)
          .fontFamily(DesignTokens.fontRound)
          .fontColor(DesignTokens.textSecondary)
        Text('可检查双方日程、作息，或放宽筛选。')
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
        hoverLift: true,
        refreshCue: this.refreshCue,
        onHoverChange: (hovered: boolean) => { this.hovered = hovered; },
        onTapCard: () => this.onTapHero()
      }) {
        if (this.variant === HeroVariant.WINDOW) {
          Row() {
            Text(this.daysWord() + ' · ' + DateLabel.mdw(dayOfStart(this.winStart)))
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
              .scale({ x: this.hovered ? 1.08 : 1, y: this.hovered ? 1.08 : 1 })
              .animation({ duration: DesignTokens.motion(this.reduceMotion, 150), curve: Curve.EaseOut })
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
              .onVisibleAreaChange([0.01], (visible: boolean) => {
                this.beatVisible = visible;
                this.onReduceMotionChanged();
              })
              // 换成 NEED_PARTNER／NO_WINDOW 时这颗心不在了，驱动器也别留在后台一帧帧写 beat
              .onDisAppear(() => { this.beatVisible = false; this.stopBeat(); })
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
