import { AppConst } from 'commons';
import { AccessibilityPolicy } from '../accessibility/AccessibilityPolicy';
import { DesignTokens } from '../theme/DesignTokens';

/** 《隐私政策》一节：标题 + 正文，两份文字都走资源引用。 */
interface PolicySection {
  title: ResourceStr;
  body: ResourceStr;
}

/**
 * 《隐私政策》全文（阶段 6R.4 / 发布清单 G4-1）。
 *
 * 全文随包出厂、离线可读——即使开闸批之后这个包带了联网权限，"政策只在浏览器里有一份"
 * 仍不成立（提审材料的在线版地址只是同一份文字的镜像）。
 * 文本与 docs/legal/privacy-policy.md（商店与托管用的那一份）、
 * docs/legal/privacy-policy.html、以及 string.json 的 `pp_*` 条目**逐字同源**，
 * 增删一节必须四处同批改；漂移由 `node tools/test/run.mjs` 的文案口径审计拦下
 * （`tools/test/copy-audit.mjs`），它会同时核对这里的**节序**。
 * 首启弹窗与「我的」页共用本组件，两处不再各写一套说法。
 */
@Component
export struct PrivacyPolicySheet {
  onClose: () => void = () => {};
  // 装饰器实参必须是字面量，取值与 SENIOR_MODE_KEY 保持一致。
  @StorageProp('crd_senior_mode') senior: boolean = false;

  /** 分节清单（资源引用在组件方法内构造，避免模块级 $r）。 */
  sections(): PolicySection[] {
    const list: PolicySection[] = [
      { title: $r('app.string.pp_head_t'), body: $r('app.string.pp_head_b') },
      { title: $r('app.string.pp_data_t'), body: $r('app.string.pp_data_b') },
      { title: $r('app.string.pp_backup_t'), body: $r('app.string.pp_backup_b') },
      { title: $r('app.string.pp_photo_t'), body: $r('app.string.pp_photo_b') },
      { title: $r('app.string.pp_perm_t'), body: $r('app.string.pp_perm_b') },
      { title: $r('app.string.pp_sys_t'), body: $r('app.string.pp_sys_b') },
      { title: $r('app.string.pp_cloud_t'), body: $r('app.string.pp_cloud_b') },
      { title: $r('app.string.pp_third_t'), body: $r('app.string.pp_third_b') },
      { title: $r('app.string.pp_minor_t'), body: $r('app.string.pp_minor_b') },
      { title: $r('app.string.pp_delete_t'), body: $r('app.string.pp_delete_b') },
      { title: $r('app.string.pp_version_t'), body: $r('app.string.pp_version_b') }
    ];
    return list;
  }

  build() {
    Column() {
      Row() {
        Text($r('app.string.privacy_policy_title'))
          .fontSize(DesignTokens.fontTitle).fontWeight(FontWeight.Bold)
          .fontColor(DesignTokens.textPrimary)
        Blank()
        Button('关闭')
          .fontSize(DesignTokens.fontCaption)
          .constraintSize({ minHeight: AccessibilityPolicy.minHit(this.senior) })
          .borderRadius(DesignTokens.radiusPill)
          .backgroundColor(DesignTokens.fillWeak).fontColor(DesignTokens.textSecondary)
          .fontWeight(FontWeight.Bold)
          .shadow(DesignTokens.jelly(DesignTokens.borderWeak, DesignTokens.jellyDepth))
          .onClick(() => this.onClose())
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 16, bottom: 10 })

      Scroll() {
        Column({ space: 14 }) {
          ForEach(this.sections(), (sec: PolicySection) => {
            Column({ space: 4 }) {
              Text(sec.title)
                .fontSize(DesignTokens.fontBody).fontWeight(FontWeight.Medium)
                .fontColor(DesignTokens.textPrimary)
              Text(sec.body)
                .fontSize(DesignTokens.fontCaption)
                .fontColor(DesignTokens.textSecondary).lineHeight(20)
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
          }, (sec: PolicySection, idx: number) => 'pp' + idx)

          // 托管地址只在填写后才显示；空串时明确"以本页为准"，不再 toast 一句"即将上线"
          Row({ space: 4 }) {
            if (AppConst.PRIVACY_POLICY_URL === '') {
              Text($r('app.string.pp_link_none'))
                .fontSize(DesignTokens.fontCaption).fontColor(DesignTokens.textHint)
            } else {
              Text($r('app.string.pp_link_prefix'))
                .fontSize(DesignTokens.fontCaption).fontColor(DesignTokens.textHint)
              Text(AppConst.PRIVACY_POLICY_URL)
                .fontSize(DesignTokens.fontCaption).fontColor(DesignTokens.textHint)
            }
          }
          .width('100%')
          .margin({ top: 4 })
        }
        .width('100%')
        .padding({ left: 20, right: 20, bottom: 28 })
        .alignItems(HorizontalAlign.Start)
      }
      .layoutWeight(1)
      .align(Alignment.Top)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(DesignTokens.card)
    // 7 分甜的 sheet 面是竖向暖白渐变，不是一块平色（原型 .sheet）
    .linearGradient(DesignTokens.sheetGradient())
    // 系统 sheet 的底色与模糊在调用处一并关掉（避免两层不透明底叠加），
    // 圆角因此由本组件自己画。
    .borderRadius({ topLeft: DesignTokens.radiusSheet, topRight: DesignTokens.radiusSheet })
    .clip(true)
  }
}
