import { promptAction } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { SettingsStore } from 'data';
import { Logger } from 'commons';
import { openPrivacyPolicy } from '../util/PrivacyUtil';

const TAG = 'PrivacyDialog';

/** 隐私政策要点条目（收集项 + 边界承诺；text 为资源引用）。 */
interface PrivacyPoint {
  icon: string;
  text: ResourceStr;
}

/**
 * 首启隐私政策弹窗（US4 / FR-007）：
 * - 全屏覆盖拦截交互，未同意前不可使用应用；
 * - 「同意并继续」→ SettingsStore.acceptPrivacy() 持久化（此后不再弹出）；
 * - 「不同意并退出」→ terminateSelf 退出应用。
 */
@Component
export struct PrivacyDialog {
  onAccepted: () => void = () => {};
  @State working: boolean = false;

  /** 同意：持久化标记后回调（Index 移除拦截）。 */
  accept(): void {
    if (this.working) {
      return;
    }
    this.working = true;
    SettingsStore.acceptPrivacy().then(() => {
      this.onAccepted();
    }).catch((e: Error) => {
      this.working = false;
      Logger.error(TAG, 'acceptPrivacy failed: ' + e.message);
      promptAction.showToast({ message: $r('app.string.privacy_save_failed') });
    });
  }

  /** 隐私要点（资源引用在组件方法内构造，避免模块级 $r）。 */
  privacyPoints(): PrivacyPoint[] {
    const pts: PrivacyPoint[] = [
      { icon: '📋', text: $r('app.string.privacy_point_local') },
      { icon: '📅', text: $r('app.string.privacy_point_calendar') },
      { icon: '📷', text: $r('app.string.privacy_point_photo') },
      { icon: '🔐', text: $r('app.string.privacy_point_cloud') }
    ];
    return pts;
  }

  /** 拒绝：退出应用（组件内经宿主上下文调用 UIAbility.terminateSelf）。 */
  decline(): void {
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      ctx.terminateSelf().catch((e: Error) => {
        Logger.error(TAG, 'terminateSelf failed: ' + e.message);
      });
    } catch (e) {
      Logger.error(TAG, 'terminateSelf error: ' + (e as Error).message);
    }
  }

  build() {
    Column() {
      // 顶部标题区
      Column({ space: 8 }) {
        Text('🤝').fontSize(40)
        Text($r('app.string.privacy_welcome_title')).fontSize(22).fontWeight(FontWeight.Bold)
        Text($r('app.string.privacy_welcome_subtitle')).fontSize(13).fontColor($r('app.color.text_tertiary'))
      }
      .alignItems(HorizontalAlign.Center)
      .width('100%')
      .margin({ top: 48, bottom: 24 })

      // 要点列表
      Scroll() {
        Column({ space: 14 }) {
          ForEach(this.privacyPoints(), (p: PrivacyPoint) => {
            Row({ space: 10 }) {
              Text(p.icon).fontSize(18)
              Text(p.text).fontSize(13).fontColor($r('app.color.text_primary')).layoutWeight(1).lineHeight(19)
            }.width('100%').alignItems(VerticalAlign.Top)
          }, (p: PrivacyPoint) => p.icon)

          // 《隐私政策》全文入口：AGC 托管 URL 就绪后 openLink 跳转；未就绪 toast 提示
          Text($r('app.string.privacy_link_fulltext'))
            .fontSize(13).fontColor($r('app.color.brand_pink'))
            .margin({ top: 6 })
            .onClick(() => {
              const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
              openPrivacyPolicy(ctx, $r('app.string.privacy_fulltext_soon'));
            })

          Text($r('app.string.privacy_level_hint'))
            .fontSize(11).fontColor($r('app.color.text_hint')).margin({ top: 4 })
        }
        .width('100%')
        .padding({ left: 24, right: 24 })
      }
      .layoutWeight(1)
      .align(Alignment.Top)

      // 底部按钮区
      Column({ space: 10 }) {
        Button($r('app.string.privacy_btn_accept'))
          .width('100%').height(46).backgroundColor($r('app.color.brand_pink'))
          .enabled(!this.working)
          .onClick(() => this.accept())
        Button($r('app.string.privacy_btn_decline'))
          .width('100%').height(46)
          .backgroundColor($r('app.color.fill_weak')).fontColor($r('app.color.text_secondary'))
          .enabled(!this.working)
          .onClick(() => this.decline())
      }
      .width('100%')
      .padding({ left: 24, right: 24, top: 12, bottom: 32 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_bg'))
  }
}
