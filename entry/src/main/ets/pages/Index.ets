import { AppNavigator } from '../navigation/AppNavigator';
import { FeatureFlags } from 'feature';
import { Logger } from 'commons';
import { Breakpoint } from '../responsive/Breakpoints';
import { ResponsiveContainer } from '../responsive/ResponsiveContainer';
import { DesignTokens } from '../theme/DesignTokens';
import { AccessibilityPolicy } from '../accessibility/AccessibilityPolicy';
import { bindToastHost } from '../util/AppToast';

/** 展开档下整壳的最大宽度：再宽只加留白，不把三 Tab 底栏拉到屏幕两头。 */
const SHELL_MAX: number = 800;

/**
 * 应用入口页：导航与三 Tab 壳层交给 AppNavigator。
 * 首启隐私声明使用商店托管服务，不再叠加应用自绘弹窗。
 *
 * 响应式（Task 5.1）：外壳由 ResponsiveContainer 量宽，expanded 档把整壳收成居中列，
 * 底色仍铺满窗口；窄屏与中屏不封顶，布局与改造前一致。档位开关是
 * FeatureFlags.responsiveV2，判定只写在 Breakpoints.ofWidth 一处（见 docs/release/rollout-and-rollback.md）。
 */
@Entry
@Component
struct Index {
  @State private bp: Breakpoint = Breakpoint.COMPACT;

  onPageShow(): void {
    AppStorage.setOrCreate<boolean>('crd_root_page_visible', true);
  }

  onPageHide(): void {
    AppStorage.setOrCreate<boolean>('crd_root_page_visible', false);
  }

  aboutToAppear(): void {
    // 灰度档位一次一记（Task 6.2）：没有远端遥测，hilog 里这一行是"这个包开了哪几档"的
    // 唯一现场证据。
    Logger.info('CrdFlags', FeatureFlags.summary());
    // 系统无障碍状态（长辈模式/屏幕朗读/减少动态效果）只在壳层订阅一次，页面读 AppStorage
    AccessibilityPolicy.attach();
    // 自绘提示条要 UIContext 才能挂上浮层：绑一次全站共用（router 页同属一个窗口）
    bindToastHost(this.getUIContext());
  }

  aboutToDisappear(): void {
    // SDK 要求 on* 监听在生命周期结束前 off，否则泄漏甚至崩溃
    AccessibilityPolicy.detach();
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

        }
        .width('100%')
        .height('100%')
      }
    }
    .width('100%')
    .height('100%')
    .linearGradient(DesignTokens.pageGradient())
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}
