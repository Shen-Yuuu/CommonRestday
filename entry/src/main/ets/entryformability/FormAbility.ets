import { FormExtensionAbility, formBindingData, formInfo, formProvider } from '@kit.FormKit';
import { Want } from '@kit.AbilityKit';
import { MIN_PER_DAY, OWNER_ME, todayEpochDay } from 'domain';
import { Db, SettingsStore } from 'data';
import {
  CardInput, CardModel, CardRoutes, CardState, CardSummaryService, CommonTimeQueryService, FeatureFlags,
  ScheduleOverviewQueryService, ScheduleUseCase
} from 'feature';
import { Logger } from 'commons';

const TAG = 'FormAbility';

/** 卡面加载态：异步回填前 CardModel.state 为空串，卡片按它渲染"正在计算"。 */
const STATE_LOADING = '';

/**
 * 2×2 服务卡片扩展（US7 / FR-013，阶段 4 Task 4.2）。
 *
 * - 内容口径与首页同源：结论一律走 CommonTimeQueryService 的首页读模型，再由 CardSummaryService
 *   投影成"一大一次"两行。卡片不再自己数窗口，避免出现第二个算法。
 * - 卡片进程可能独立于 EntryAbility 启动：本文件自行 Db/SettingsStore 初始化，
 *   任一步失败都降级为占位文案，绝不抛给卡片框架。
 * - 只做本机读算：不拉云快照、不推配对数据（云端不是主库，卡片更不是）。
 * - 灰度回退（Task 6.2）：FeatureFlags.newCard = false 时两个入口都只下发停用文案，
 *   不读库也不重算——关掉的是内容链路，不是卡片在桌面上的存在与否。
 * - 跨天刷新：周期更新（updateDuration）与日切后首次拉起会先本机重算一次，
 *   让"结果是上一轮的"只在重算失败时出现，而不是每天早晨必现。
 * - 点击带 route 参数：取值是 NavRoutes 白名单里的名字，壳层落地前还会按白名单再验一次。
 *
 * form_config.json 里刻意去掉了两项，别再顺手加回来：
 * - formConfigAbility 要的是"卡片配置页"的 UIAbility（activity://...），指到 FormAbility
 *   这个 FormExtensionAbility 上是空转，本机也没有配置页流程；
 * - scheduledUpdateTime 与 updateDuration 不能并存：按 form_config 规则，两者同时配置时
 *   只按定点时间刷新，那样 6 小时刷新就成了摆设，"今晚"的答案会一整天停在凌晨那一版。
 */
export default class FormAbility extends FormExtensionAbility {
  onAddForm(want: Want): formBindingData.FormBindingData {
    if (!FeatureFlags.newCard) {
      // 回退档：卡片还在桌面（添加动作发生在系统侧，应用拦不住），但一句假结论都不下发
      Logger.info(TAG, 'onAddForm: card off, publishing disabled placeholder');
      return formBindingData.createFormBindingData(JSON.stringify(FormAbility.disabled()));
    }
    let formId = '';
    try {
      const params = want.parameters;
      if (params != null) {
        const v: Object = params[formInfo.FormParam.IDENTITY_KEY];
        if (v != null) {
          formId = v as string;
        }
      }
    } catch (e) {
      // 取 formId 失败不影响占位数据返回（ArkTS Card 数据必须 JSON 字符串形式）
    }
    if (formId !== '') {
      this.refreshCard(formId).catch((e: Error) => {
        Logger.warn(TAG, 'refresh card on add failed: ' + e.message);
      });
    }
    return formBindingData.createFormBindingData(JSON.stringify(FormAbility.placeholder()));
  }

  onRemoveForm(formId: string): void {
    // 空实现：卡片数据为读缓存快照，无需清理
  }

  onUpdateForm(formId: string): void {
    this.refreshCard(formId).catch((e: Error) => {
      Logger.warn(TAG, 'refresh card on update failed: ' + e.message);
    });
  }

  /** 组装真实卡片数据并回填指定卡片；存储初始化/读取任一步失败均降级（保持占位内容）。 */
  private async refreshCard(formId: string): Promise<void> {
    if (!FeatureFlags.newCard) {
      // 周期更新与日切拉起都走这里：关档时连 Db.init 和本机重算都不做，卡片只保留停用文案。
      // 下发失败要留痕：卡面会一直停在"正在计算…"，没日志就分不清是关档还是故障。
      try {
        await formProvider.updateForm(formId,
          formBindingData.createFormBindingData(JSON.stringify(FormAbility.disabled())));
      } catch (e) {
        Logger.warn(TAG, 'disabled card push failed: ' + (e as Error).message);
      }
      return;
    }
    await Db.init(this.context);
    await SettingsStore.init(this.context);
    const data = await FormAbility.buildCardData();
    await formProvider.updateForm(formId, formBindingData.createFormBindingData(JSON.stringify(data)));
  }

  /** 占位数据（添加瞬间展示，随后被异步回填覆盖）。 */
  static placeholder(): CardModel {
    const m: CardModel = {
      state: STATE_LOADING, question: '同休日', hero: '正在计算…', heroNote: '',
      second: '', footer: '', route: CardRoutes.HOME
    };
    return m;
  }

  /**
   * 回退档卡面（FeatureFlags.newCard = false）。
   * state 借用 STALE 只作数据口径（卡面只渲染下面几个字符串，state 不参与排版，
   * 见 widget/RestCard2x2.ets）；语义是"这份结论不会再更新"，与 degraded() 同一类。
   * 文案里不出现日程、时间或计划标题：关档时卡片不再读任何本机数据，文案也就必须是常数。
   */
  static disabled(): CardModel {
    const m: CardModel = {
      state: CardState.STALE, question: '同休日', hero: '桌面卡片已停用',
      heroNote: '当前版本未开启卡片内容，打开 App 查看共同时间', second: '', footer: '',
      route: CardRoutes.HOME
    };
    return m;
  }

  /** 读失败时的兜底：说"读不到"而不是"没有共同时间"，两者对用户是完全不同的事实。 */
  static degraded(): CardModel {
    const m: CardModel = {
      state: CardState.STALE, question: '共同时间', hero: '暂时读不到结果',
      heroNote: '打开 App 会自动重新计算', second: '', footer: '', route: CardRoutes.HOME
    };
    return m;
  }

  /** 首页读模型 → 卡片投影；跨天先本机重算一次再投影。 */
  static async buildCardData(): Promise<CardModel> {
    const nowMin = todayEpochDay() * MIN_PER_DAY + FormAbility.minutesNow();
    try {
      let home = await CommonTimeQueryService.getHomeSummary(nowMin);
      const overview = await ScheduleOverviewQueryService.getOverview(OWNER_ME);
      const hasSchedule = overview.hasTemplate || overview.overrides > 0 || overview.courses > 0;
      if (hasSchedule && home.stale) {
        await ScheduleUseCase.recompute(todayEpochDay());
        home = await CommonTimeQueryService.getHomeSummary(nowMin);
      }
      const input: CardInput = { home: home, hasSchedule: hasSchedule };
      return CardSummaryService.of(input);
    } catch (e) {
      Logger.warn(TAG, 'card read degraded: ' + (e as Error).message);
      return FormAbility.degraded();
    }
  }

  static minutesNow(): number {
    const d = new Date();
    return d.getHours() * 60 + d.getMinutes();
  }
}
