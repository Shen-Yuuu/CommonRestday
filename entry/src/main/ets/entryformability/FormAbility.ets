import { FormExtensionAbility, formBindingData, formInfo, formProvider } from '@kit.FormKit';
import { Want } from '@kit.AbilityKit';
import { Interval, MIN_PER_DAY, todayEpochDay } from 'domain';
import { Db, ScheduleRepo, SettingsStore } from 'data';
import { ScheduleUseCase } from 'feature';
import { DateLabel, Logger } from 'commons';

const TAG = 'FormAbility';

/** 2x2 卡片数据（键与 RestCard2x2 的 LocalStorageProp 一一对应，须以 JSON 字符串下发）。 */
interface CardData {
  /** 标题：已配对"下次同休" / 未配对"我的下次休息"。 */
  title: string;
  /** 倒计时天数（窗口开始日 - 今天）；-1 表示暂无窗口（占位态）。 */
  days: number;
  /** 窗口开始日文案，如"9月20日 周日"。 */
  dateText: string;
  /** 次窗口摘要，如"15:00–22:30 · 7小时30分钟"。 */
  windowText: string;
  /** 是否存在伴侣档案（未配对时卡片展示引导文案）。 */
  hasPartner: boolean;
}

/**
 * 2x2 服务卡片扩展（US7 / FR-013）：
 * - onAddForm：同步返回占位数据（卡片框架要求立即返回），异步读共同窗口缓存计算后 updateForm 回填；
 * - 数据来源：computed_window 缓存（ScheduleRepo.listWindows）；缓存为空时触发一次重算（毫秒级）；
 * - 卡片进程可能独立于 EntryAbility 启动，先自行初始化 Db/SettingsStore，任何失败静默降级保持占位内容；
 * - onUpdateForm：周期刷新（updateDuration=1，约 30 分钟）时重算倒计时，保证跨天后天数不过期。
 */
export default class FormAbility extends FormExtensionAbility {
  onAddForm(want: Want): formBindingData.FormBindingData {
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
    await Db.init(this.context);
    await SettingsStore.init(this.context);
    const data = await FormAbility.buildCardData();
    await formProvider.updateForm(formId, formBindingData.createFormBindingData(JSON.stringify(data)));
  }

  /** 占位数据（添加瞬间展示，随后被异步回填覆盖）。 */
  static placeholder(): CardData {
    const d: CardData = {
      title: '下次同休',
      days: -1,
      dateText: '',
      windowText: '正在计算…',
      hasPartner: false
    };
    return d;
  }

  /** 读缓存组装卡片数据：最近一个未结束窗口 → 倒计时天数 + 次窗口摘要。 */
  static async buildCardData(): Promise<CardData> {
    const d = FormAbility.placeholder();
    d.windowText = '暂无窗口';
    try {
      d.hasPartner = SettingsStore.getPartnerProfile() != null;
    } catch (e) {
      Logger.warn(TAG, 'partner profile read degraded: ' + (e as Error).message);
    }
    d.title = d.hasPartner ? '下次同休' : '我的下次休息';
    try {
      let ivs: Interval[] = await ScheduleRepo.listWindows();
      if (ivs.length === 0) {
        // 无缓存（首次添加卡片/清数据后）：触发一次重算再读（毫秒级本地计算）
        await ScheduleUseCase.recompute(todayEpochDay());
        ivs = await ScheduleRepo.listWindows();
      }
      const today = todayEpochDay();
      const nowMin = today * MIN_PER_DAY + FormAbility.minutesNow();
      // 最近一个未结束窗口（listWindows 已按开始时间升序）
      let next: Interval | null = null;
      for (let i = 0; i < ivs.length; i++) {
        if (ivs[i].end > nowMin) {
          next = ivs[i];
          break;
        }
      }
      if (next != null) {
        const day = Math.floor(next.start / MIN_PER_DAY);
        d.days = day - today;
        d.dateText = DateLabel.mdw(day);
        d.windowText = DateLabel.hm(next.start) + '–' + DateLabel.hm(next.end)
          + ' · ' + DateLabel.duration(next.end - next.start);
      }
    } catch (e) {
      Logger.warn(TAG, 'window cache read degraded: ' + (e as Error).message);
    }
    return d;
  }

  static minutesNow(): number {
    const d = new Date();
    return d.getHours() * 60 + d.getMinutes();
  }
}
