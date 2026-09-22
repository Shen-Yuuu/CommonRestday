import { AppNavigator } from '../navigation/AppNavigator';
import { PrivacyDialog } from '../component/PrivacyDialog';
import { SettingsStore } from 'data';
import { Logger } from 'commons';
import { common } from '@kit.AbilityKit';

/**
 * 应用入口页：只负责首启隐私拦截，导航与三 Tab 壳层交给 AppNavigator。
 * 遮罩盖在 Navigation 之上，未同意前整棵导航树（含栈目的地）都点不到。
 */
@Entry
@Component
struct Index {
  // 首启隐私拦截（US4 / FR-007）：未同意前全屏覆盖，拦截交互
  @State showPrivacy: boolean = false;

  aboutToAppear(): void {
    this.checkPrivacy();
  }

  /**
   * 读取首启隐私标记：
   * - 快路径：SettingsStore 已就绪（EntryAbility 完成初始化）时同步判定，无闪烁；
   * - 慢路径：await 幂等 init 后重读；
   * - 失败按未同意处理（宁可重弹不可漏弹）。
   */
  async checkPrivacy(): Promise<void> {
    try {
      this.showPrivacy = !SettingsStore.isPrivacyAccepted();
      return;
    } catch (e) {
      // SettingsStore 未就绪：走慢路径等待初始化完成
    }
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      await SettingsStore.init(ctx);
      this.showPrivacy = !SettingsStore.isPrivacyAccepted();
    } catch (e) {
      this.showPrivacy = true;
      Logger.error('Index', 'privacy check failed, treat as not accepted');
    }
  }

  onPrivacyAccepted(): void {
    this.showPrivacy = false;
  }

  build() {
    Stack() {
      AppNavigator()

      // 首启隐私弹窗：全屏覆盖拦截（同意后不再出现）
      if (this.showPrivacy) {
        PrivacyDialog({
          onAccepted: () => this.onPrivacyAccepted()
        })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_bg_warm'))
  }
}
