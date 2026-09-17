import { router, SymbolGlyphModifier, TextModifier } from '@kit.ArkUI';
import { HdsListItem, IconSize, PrefixIcon, SuffixArrow } from '@kit.UIDesignKit';
import { OWNER_ME, OWNER_PARTNER } from 'domain';
import { AppConst } from 'commons';
import { ScheduleUseCase } from 'feature';
import { OwnerRouteParam } from '../model/RouteParams';
import { navToMe } from '../util/NavUtil';

/** 班表页：我/伴侣双侧入口（本机代录），伴侣侧复用同一套录入链路。 */
@Component
export struct ScheduleHub {
  @State side: string = OWNER_ME;
  @State partnerExists: boolean = false;
  // 保存动作 → 重算广播 → 伴侣档案可能已增删，重新检查
  @StorageProp('recomputeCount') @Watch('onRecomputeChanged') recomputeCount: number = 0;

  aboutToAppear(): void {
    this.checkPartner();
  }

  onRecomputeChanged(): void {
    this.checkPartner();
  }

  checkPartner(): void {
    ScheduleUseCase.hasPartnerContext().then((ok: boolean) => {
      this.partnerExists = ok;
    }).catch(() => {
      this.partnerExists = false;
    });
  }

  go(page: string): void {
    const p: OwnerRouteParam = { owner: this.side };
    router.pushUrl({ url: page, params: p });
  }

  sideTitle(): string {
    return this.side === OWNER_ME ? '我的班表' : 'TA 的班表';
  }

  /** 前缀图标：SymbolGlyphModifier 需先实例化再设色（链式返回父类会丢失类型）。 */
  prefixIcon(res: Resource): SymbolGlyphModifier {
    const m = new SymbolGlyphModifier(res);
    m.fontColor([$r('app.color.brand_pink')]);
    return m;
  }

  build() {
    Scroll() {
      Column({ space: 12 }) {
        Text('班表').fontSize(22).fontWeight(FontWeight.Bold)
          .margin({ top: 16, bottom: 4 })
          .width('100%')

        // 我 / 伴侣 分段切换
        Row({ space: 0 }) {
          Text('我的').fontSize(14).textAlign(TextAlign.Center)
            .layoutWeight(1).padding({ top: 8, bottom: 8 })
            .borderRadius(10)
            .backgroundColor(this.side === OWNER_ME ? $r('app.color.brand_pink') : $r('app.color.card_bg'))
            .fontColor(this.side === OWNER_ME ? '#FFFFFF' : $r('app.color.text_secondary'))
            .onClick(() => this.side = OWNER_ME)
          Text('伴侣').fontSize(14).textAlign(TextAlign.Center)
            .layoutWeight(1).padding({ top: 8, bottom: 8 })
            .borderRadius(10)
            .backgroundColor(this.side === OWNER_PARTNER ? $r('app.color.brand_pink') : $r('app.color.card_bg'))
            .fontColor(this.side === OWNER_PARTNER ? '#FFFFFF' : $r('app.color.text_secondary'))
            .onClick(() => {
              this.side = OWNER_PARTNER;
              this.checkPartner();
            })
        }
        .width('100%').padding(4).borderRadius(14).backgroundColor($r('app.color.fill_soft'))

        if (this.side === OWNER_PARTNER && !this.partnerExists) {
          // 无伴侣档案：引导去「我的」页添加
          Column({ space: 10 }) {
            Text('还没有伴侣档案').fontSize(16).fontWeight(FontWeight.Medium)
            Text('先到「我的」页添加伴侣（本机代录），再回到这里为 TA 录入课表/班表，即可计算你们的共同时间。')
              .fontSize(12).fontColor($r('app.color.text_tertiary')).textAlign(TextAlign.Center)
            Button('去添加伴侣').backgroundColor($r('app.color.brand_pink'))
              .onClick(() => navToMe())
          }
          .alignItems(HorizontalAlign.Center)
          .width('100%').padding({ top: 32, bottom: 32, left: 24, right: 24 })
          .borderRadius(20).backgroundColor($r('app.color.card_bg'))
          .shadow({ radius: 16, color: $r('app.color.shadow_soft'), offsetX: 0, offsetY: 4 })
        } else {
          Text(this.side === OWNER_ME
            ? '先录入一次，之后换班只需涂抹修改。配对后这里的数据会按隐私等级共享给对方。'
            : '在这里代录 TA 的课表/班表（与你的数据完全隔离保存）。保存后共同时间会自动重算。')
            .fontSize(12).fontColor($r('app.color.text_tertiary')).width('100%')

          Text(this.sideTitle()).fontSize(16).fontWeight(FontWeight.Medium).width('100%')

          // HDS 规范列表项（@since 20）：图标 + 主副文本 + 箭头，系统按压态与无障碍
          List({ space: 12 }) {
            HdsListItem({
              hdsListItemCard: {
                prefixItem: new PrefixIcon({
                  iconSize: IconSize.SYSTEM_ICON,
                  iconValue: { symbol: this.prefixIcon($r('sys.symbol.arrow_clockwise')) }
                }),
                textItem: {
                  primaryText: {
                    text: '循环模板',
                    modifier: new TextModifier().fontSize(16).fontWeight(FontWeight.Medium)
                      .fontColor($r('app.color.text_primary'))
                  },
                  secondaryText: {
                    text: '白白夜夜休休 / 上二休二 / 自定义循环，自动展开未来 ' + AppConst.HORIZON_DAYS + ' 天',
                    modifier: new TextModifier().fontSize(12).fontColor($r('app.color.text_tertiary'))
                  }
                },
                suffixItem: new SuffixArrow({ color: $r('app.color.text_disabled') }),
                cardBackgroundColor: $r('app.color.card_bg'),
                cardBorderRadius: 20,
                cardPrefixMargin: 0,
                cardSuffixMargin: 0,
                onClick: () => this.go('pages/CycleEditor')
              }
            })
            HdsListItem({
              hdsListItemCard: {
                prefixItem: new PrefixIcon({
                  iconSize: IconSize.SYSTEM_ICON,
                  iconValue: { symbol: this.prefixIcon($r('sys.symbol.paintbrush')) }
                }),
                textItem: {
                  primaryText: {
                    text: '月历涂抹',
                    modifier: new TextModifier().fontSize(16).fontWeight(FontWeight.Medium)
                      .fontColor($r('app.color.text_primary'))
                  },
                  secondaryText: {
                    text: '像涂色一样逐日标记班次、换班、请假，长按清除',
                    modifier: new TextModifier().fontSize(12).fontColor($r('app.color.text_tertiary'))
                  }
                },
                suffixItem: new SuffixArrow({ color: $r('app.color.text_disabled') }),
                cardBackgroundColor: $r('app.color.card_bg'),
                cardBorderRadius: 20,
                cardPrefixMargin: 0,
                cardSuffixMargin: 0,
                onClick: () => this.go('pages/PaintMonth')
              }
            })
            HdsListItem({
              hdsListItemCard: {
                prefixItem: new PrefixIcon({
                  iconSize: IconSize.SYSTEM_ICON,
                  iconValue: { symbol: this.prefixIcon($r('sys.symbol.square_and_pencil')) }
                }),
                textItem: {
                  primaryText: {
                    text: '课程表导入',
                    modifier: new TextModifier().fontSize(16).fontWeight(FontWeight.Medium)
                      .fontColor($r('app.color.text_primary'))
                  },
                  secondaryText: {
                    text: '大学生场景：粘贴课表文本 / 拍照识别 / 手动添加',
                    modifier: new TextModifier().fontSize(12).fontColor($r('app.color.text_tertiary'))
                  }
                },
                suffixItem: new SuffixArrow({ color: $r('app.color.text_disabled') }),
                cardBackgroundColor: $r('app.color.card_bg'),
                cardBorderRadius: 20,
                cardPrefixMargin: 0,
                cardSuffixMargin: 0,
                onClick: () => this.go('pages/CourseImport')
              }
            })
            HdsListItem({
              hdsListItemCard: {
                prefixItem: new PrefixIcon({
                  iconSize: IconSize.SYSTEM_ICON,
                  iconValue: { symbol: this.prefixIcon($r('sys.symbol.gearshape')) }
                }),
                textItem: {
                  primaryText: {
                    text: '班次类型管理',
                    modifier: new TextModifier().fontSize(16).fontWeight(FontWeight.Medium)
                      .fontColor($r('app.color.text_primary'))
                  },
                  secondaryText: {
                    text: '配置上下班时间、通勤、夜班恢复时长等参数',
                    modifier: new TextModifier().fontSize(12).fontColor($r('app.color.text_tertiary'))
                  }
                },
                suffixItem: new SuffixArrow({ color: $r('app.color.text_disabled') }),
                cardBackgroundColor: $r('app.color.card_bg'),
                cardBorderRadius: 20,
                cardPrefixMargin: 0,
                cardSuffixMargin: 0,
                onClick: () => this.go('pages/ScheduleEditor')
              }
            })
          }
          .width('100%')
          .scrollBar(BarState.Off)
        }
      }
      .padding(16)
      .width('100%')
    }
    .width('100%').height('100%')
    .backgroundColor($r('app.color.page_bg_warm'))
    .align(Alignment.Top)
  }
}
