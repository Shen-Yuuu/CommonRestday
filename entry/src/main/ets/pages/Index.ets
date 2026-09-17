import { HomeView } from '../view/HomeView';
import { CoTimeView } from '../view/CoTimeView';
import { ScheduleHub } from '../view/ScheduleHub';
import { MeView } from '../view/MeView';
import { PrivacyDialog } from '../component/PrivacyDialog';
import { SettingsStore } from 'data';
import { Logger } from 'commons';
import { common } from '@kit.AbilityKit';

/** 底部页签：同休 / 共同 / 班表 / 我的（计划并入「共同」页分段）。 */
@Entry
@Component
struct Index {
  @State activeTab: number = 0;
  // 首启隐私拦截（US4 / FR-007）：未同意前全屏覆盖，拦截交互
  @State privacyChecked: boolean = false;
  @State showPrivacy: boolean = false;
  // 跨 Tab 导航广播（「去添加伴侣」等入口）：NavUtil.navToMe() 触发
  @StorageProp('navToMeCount') @Watch('onNavToMe') navToMeCount: number = 0;
  // 跨 Tab 导航广播（计划页空态引导「去共同时间页」）：NavUtil.navToCoTime() 触发
  @StorageProp('navToCoTimeCount') @Watch('onNavToCoTime') navToCoTimeCount: number = 0;

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
      this.applyPrivacyState(SettingsStore.isPrivacyAccepted());
      return;
    } catch (e) {
      // SettingsStore 未就绪：走慢路径等待初始化完成
    }
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      await SettingsStore.init(ctx);
      this.applyPrivacyState(SettingsStore.isPrivacyAccepted());
    } catch (e) {
      this.applyPrivacyState(false);
      Logger.error('Index', 'privacy check failed, treat as not accepted');
    }
  }

  applyPrivacyState(accepted: boolean): void {
    this.privacyChecked = true;
    this.showPrivacy = !accepted;
  }

  onNavToMe(): void {
    this.activeTab = 3;
  }

  onNavToCoTime(): void {
    this.activeTab = 1;
  }

  onPrivacyAccepted(): void {
    this.showPrivacy = false;
  }

  build() {
    Stack() {
      Tabs({ barPosition: BarPosition.End, index: this.activeTab }) {
        TabContent() {
          HomeView()
        }
        .tabBar(this.tabLabel($r('sys.symbol.house'), '同休', 0))

        TabContent() {
          CoTimeView()
        }
        .tabBar(this.tabLabel($r('sys.symbol.heart'), '共同', 1))

        TabContent() {
          ScheduleHub()
        }
        .tabBar(this.tabLabel($r('sys.symbol.calendar'), '班表', 2))

        TabContent() {
          MeView()
        }
        .tabBar(this.tabLabel($r('sys.symbol.person'), '我的', 3))
      }
      .scrollable(false)
      .barHeight(64)
      .onChange((idx: number) => {
        this.activeTab = idx;
      })

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

  @Builder
  tabLabel(icon: Resource, text: string, idx: number) {
    Column({ space: 2 }) {
      SymbolGlyph(icon)
        .fontSize(22)
        .fontColor(this.activeTab === idx ? [$r('app.color.brand_pink')] : [$r('app.color.text_tertiary')])
      Text(text)
        .fontSize(11)
        .fontColor(this.activeTab === idx ? $r('app.color.brand_pink') : $r('app.color.text_tertiary'))
        .fontWeight(this.activeTab === idx ? FontWeight.Bold : FontWeight.Normal)
    }
    .width('100%')
    .justifyContent(FlexAlign.Center)
  }
}
