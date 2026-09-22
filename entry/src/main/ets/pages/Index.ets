import { AppNavigator } from '../navigation/AppNavigator';
import { PrivacyDialog } from '../component/PrivacyDialog';
import { SettingsStore } from 'data';
import { Logger } from 'commons';
import { common } from '@kit.AbilityKit';
import { Breakpoint } from '../responsive/Breakpoints';
import { ResponsiveContainer } from '../responsive/ResponsiveContainer';
import { AccessibilityPolicy } from '../accessibility/AccessibilityPolicy';

/** 展开档下整壳的最大宽度：再宽只加留白，不把三 Tab 底栏拉到屏幕两头。 */
const SHELL_MAX: number = 800;

/**
 * 应用入口页：只负责首启隐私拦截，导航与三 Tab 壳层交给 AppNavigator。
 * 遮罩盖在 Navigation 之上，未同意前整棵导航树（含栈目的地）都点不到。
 *
 * 响应式（Task 5.1）：外壳由 ResponsiveContainer 量宽，expanded 档把整壳收成居中列，
 * 底色仍铺满窗口；窄屏与中屏不封顶，布局与改造前一致。
 */
@Entry
@Component
struct Index {
  // 首启隐私拦截（US4 / FR-007）：未同意前全屏覆盖，拦截交互
  @State showPrivacy: boolean = false;
  @State private bp: Breakpoint = Breakpoint.COMPACT;

  aboutToAppear(): void {
    this.checkPrivacy();
    // 系统无障碍状态（长辈模式/屏幕朗读/减少动态效果）只在壳层订阅一次，页面读 AppStorage
    AccessibilityPolicy.attach();
  }

  aboutToDisappear(): void {
    // SDK 要求 on* 监听在生命周期结束前 off，否则泄漏甚至崩溃
    AccessibilityPolicy.detach();
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

  /** 内容列上限：expanded 收成居中列，其余档位与改造前一模一样（不封顶）。 */
  private shellMax(): Length {
    return this.bp === Breakpoint.EXPANDED ? SHELL_MAX : '100%';
  }

  build() {
    // @Entry 的根节点必须是容器组件，量宽的 ResponsiveContainer 放在它里面
    Stack() {
      ResponsiveContainer({ breakpoint: this.bp }) {
        Stack() {
          // 内容列：宽屏下居中封顶，底色由最外层铺满，两侧不会露出系统默认底
          Stack() {
            AppNavigator()
          }
          .width('100%')
          .height('100%')
          .constraintSize({ maxWidth: this.shellMax() })

          // 首启隐私弹窗：全屏覆盖拦截（同意后不再出现）。放在封顶之外，
          // 宽屏下两侧留白也在遮罩里，未同意时整棵导航树都点不到。
          if (this.showPrivacy) {
            PrivacyDialog({
              onAccepted: () => this.onPrivacyAccepted()
            })
          }
        }
        .width('100%')
        .height('100%')
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_bg_warm'))
  }
}
