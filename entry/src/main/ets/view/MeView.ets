import { promptAction } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { reminderAgentManager } from '@kit.BackgroundTasksKit';
import { EngineParams, hhmmToMin, minToHHmm } from 'domain';
import {
  PAIRED, PAIR_NONE, PAIR_WAITING, PartnerProfile, ScheduleRepo, SettingsStore
} from 'data';
import { AgcPairingClient, PairingSession, SnapshotCrypto } from 'cloud';
import { AppConst, Logger } from 'commons';
import { ScheduleUseCase } from 'feature';
import { openPrivacyPolicy } from '../util/PrivacyUtil';

const TAG = 'MeView';

/** 我的页：伴侣档案（本机代录）、云端配对、我的作息参数、隐私等级、数据管理。 */
@Component
export struct MeView {
  @State shareLevel: number = 2;
  @State pairState: string = PAIR_NONE;
  // 云端配对区块
  @State pairingBusy: boolean = false;
  @State showJoinInput: boolean = false;
  @State myCode: string = '';
  @State joinCode: string = '';
  @State clearing: boolean = false;
  // 伴侣档案区块
  @State partnerExists: boolean = false;
  @State partnerEditing: boolean = false;
  @State pNick: string = '';
  @State pWake: string = '07:00';
  @State pBed: string = '22:30';
  @State pWind: string = '20';
  // 我的引擎参数区块
  @State myEditing: boolean = false;
  @State myWake: string = '07:00';
  @State myBed: string = '22:30';
  @State myWind: string = '20';
  @State myHorizon: string = '120';

  aboutToAppear(): void {
    this.reload();
  }

  reload(): void {
    try {
      this.shareLevel = SettingsStore.getShareLevel();
      this.pairState = SettingsStore.getPairState();
    } catch (e) {
      // Settings 未初始化时保持默认
    }
    this.reloadPartner();
    this.reloadMyParams();
  }

  reloadPartner(): void {
    let profile: PartnerProfile | null = null;
    try {
      profile = SettingsStore.getPartnerProfile();
    } catch (e) {
      profile = null;
    }
    this.partnerExists = profile != null;
    if (profile != null && !this.partnerEditing) {
      this.pNick = profile.nick;
      this.pWake = minToHHmm(profile.wakeMin);
      this.pBed = minToHHmm(profile.bedMin);
      this.pWind = '' + profile.windDownMin;
    }
  }

  // ---------- 伴侣档案：添加 / 编辑 / 删除 ----------

  startAddPartner(): void {
    this.pNick = '';
    this.pWake = '07:00';
    this.pBed = '22:30';
    this.pWind = '20';
    this.partnerEditing = true;
  }

  startEditPartner(): void {
    this.reloadPartner();
    this.partnerEditing = true;
  }

  cancelPartnerEdit(): void {
    this.partnerEditing = false;
    this.reloadPartner();
  }

  savePartner(): void {
    const nick = this.pNick.trim();
    const wake = hhmmToMin(this.pWake);
    const bed = hhmmToMin(this.pBed);
    const wind = this.toInt(this.pWind, -1);
    if (nick === '') {
      promptAction.showToast({ message: '请填写伴侣昵称' });
      return;
    }
    if (wake < 0 || bed < 0) {
      promptAction.showToast({ message: '时间格式应为 HH:MM（如 07:00）' });
      return;
    }
    if (bed <= wake) {
      promptAction.showToast({ message: '就寝时间需晚于起床时间' });
      return;
    }
    if (wind < 0) {
      promptAction.showToast({ message: '收整缓冲不能为负' });
      return;
    }
    const profile: PartnerProfile = { nick: nick, wakeMin: wake, bedMin: bed, windDownMin: wind };
    SettingsStore.savePartnerProfile(profile).then(() => {
      return ScheduleUseCase.onScheduleChanged();
    }).then(() => {
      this.partnerEditing = false;
      this.reloadPartner();
      promptAction.showToast({ message: '伴侣档案已保存，共同时间已重算' });
    }).catch((e: Error) => {
      promptAction.showToast({ message: '保存失败：' + e.message });
    });
  }

  confirmDeletePartner(): void {
    this.getUIContext().showAlertDialog({
      title: '删除伴侣档案',
      message: '将同时清除 TA 的全部班表/课表数据，并回退到单人模式。确定删除？',
      primaryButton: {
        value: '删除',
        action: () => this.doDeletePartner()
      },
      secondaryButton: {
        value: '取消',
        action: () => {
        }
      }
    });
  }

  doDeletePartner(): void {
    SettingsStore.clearPartnerProfile().then(() => {
      return ScheduleRepo.deletePartnerData();
    }).then(() => {
      return ScheduleUseCase.onScheduleChanged();
    }).then(() => {
      this.partnerEditing = false;
      this.reloadPartner();
      promptAction.showToast({ message: '已删除伴侣数据，回退单人模式' });
    }).catch((e: Error) => {
      promptAction.showToast({ message: '删除失败：' + e.message });
    });
  }

  toInt(text: string, dft: number): number {
    const v = Number.parseInt(text, 10);
    return Number.isNaN(v) ? dft : v;
  }

  // ---------- 云端配对（US9 / FR-015：AGC 未就绪时全程降级提示，不影响本机代录） ----------

  pairStateText(): string {
    if (this.pairState === PAIRED) {
      return '已配对';
    }
    if (this.pairState === PAIR_WAITING) {
      return '等待对方加入';
    }
    return '未配对';
  }

  /**
   * 生成邀请码（创建方）：
   * 稳定 uid（SettingsStore 持久化）→ pairing-create 云函数 →
   * 保存 pairId + 由邀请码派生的快照加密密钥（deriveKeyHex，双方同码同钥）→ 状态 WAITING。
   * 失败（AGC 未开通/网络异常）统一降级提示，引导本机代录。
   */
  createInvite(): void {
    if (this.pairingBusy) {
      return;
    }
    this.pairingBusy = true;
    SettingsStore.getOrCreateUid().then((uid: string) => {
      return new AgcPairingClient().createPairing(uid);
    }).then(async (session: PairingSession) => {
      await SettingsStore.savePairId(session.sessionId);
      await SettingsStore.savePairKey(SnapshotCrypto.deriveKeyHex(session.code));
      await SettingsStore.setPairState(PAIR_WAITING, '');
      this.myCode = session.code;
      this.joinCode = '';
      this.showJoinInput = false;
      this.pairState = PAIR_WAITING;
      this.pairingBusy = false;
      promptAction.showToast({ message: '配对码已生成，发给 TA 吧' });
    }).catch((e: Error) => {
      this.pairingBusy = false;
      Logger.warn(TAG, 'createPairing degraded: ' + e.message);
      promptAction.showToast({ message: '云端配对暂未开放（需开通 AGC 云服务），可先用本机代录' });
    });
  }

  /** 输码加入（加入方）：pairing-join 云函数按邀请码找回会话 → 保存 pairId/密钥 → 状态 PAIRED 并推送首份快照。 */
  joinByCode(): void {
    const code = this.joinCode.trim();
    if (code.length !== 6 || Number.isNaN(Number(code))) {
      promptAction.showToast({ message: '请输入对方分享的 6 位配对码' });
      return;
    }
    if (this.pairingBusy) {
      return;
    }
    this.pairingBusy = true;
    SettingsStore.getOrCreateUid().then((uid: string) => {
      const client = new AgcPairingClient();
      return client.joinPairing(code, uid);
    }).then(async (session: PairingSession) => {
      await SettingsStore.savePairId(session.sessionId);
      await SettingsStore.savePairKey(SnapshotCrypto.deriveKeyHex(code));
      await SettingsStore.setPairState(PAIRED, '');
      this.pairState = PAIRED;
      this.pairingBusy = false;
      this.showJoinInput = false;
      this.joinCode = '';
      promptAction.showToast({ message: '配对成功，班表将按隐私等级加密同步' });
      ScheduleUseCase.onScheduleChanged().catch(() => {
      });
    }).catch((e: Error) => {
      this.pairingBusy = false;
      Logger.warn(TAG, 'joinPairing degraded: ' + e.message);
      promptAction.showToast({ message: '加入失败：云端配对暂未开放或配对码无效' });
    });
  }

  /** 创建方确认完成配对（体验版：无服务端推送，对方输码后手动确认；pairId/密钥沿用创建时保存值）。 */
  async markPaired(): Promise<void> {
    await SettingsStore.setPairState(PAIRED, '');
    this.pairState = PAIRED;
    promptAction.showToast({ message: '已进入配对模式，班表变更将加密同步' });
    ScheduleUseCase.onScheduleChanged().catch(() => {
    });
  }

  /** 取消等待中的配对（清除 pairId/密钥/状态，不动本机代录数据）。 */
  async cancelWaiting(): Promise<void> {
    await SettingsStore.savePairId('');
    await SettingsStore.clearPairKey();
    await SettingsStore.setPairState(PAIR_NONE, '');
    this.pairState = PAIR_NONE;
    this.myCode = '';
  }

  /** 解除配对（二次确认）：云端尽力解绑 → 清除本地配对标记/密钥/对方快照游标 → 重算。 */
  askUnpair(): void {
    this.getUIContext().showAlertDialog({
      message: '解除配对后不再同步 TA 的加密快照（本机代录数据不受影响）。确定解除？',
      primaryButton: {
        value: '取消',
        action: () => {
        }
      },
      secondaryButton: {
        value: '解除配对',
        fontColor: $r('app.color.danger_red'),
        action: () => this.doUnpair()
      }
    });
  }

  async doUnpair(): Promise<void> {
    const pairId = SettingsStore.getPairId();
    const uid = await SettingsStore.getOrCreateUid();
    // 云端解绑尽力而为（AGC 未就绪/已失效均忽略），本地状态照常清理
    try {
      await new AgcPairingClient().unpair(pairId, uid);
    } catch (e) {
      Logger.warn(TAG, 'unpair cloud degraded: ' + (e as Error).message);
    }
    await SettingsStore.savePairId('');
    await SettingsStore.clearPairKey();
    await SettingsStore.setPartnerSnapVer(0);
    await SettingsStore.setPairState(PAIR_NONE, '');
    this.pairState = PAIR_NONE;
    this.myCode = '';
    promptAction.showToast({ message: '已解除配对' });
    ScheduleUseCase.onScheduleChanged().catch(() => {
    });
  }

  // ---------- 数据管理 ----------

  /** 清空我的全部数据（二次确认）：8 张 RDB 表 + 全部设置；隐私同意标记保留（避免重启重复弹窗）。 */
  askClearAll(): void {
    if (this.clearing) {
      return;
    }
    this.getUIContext().showAlertDialog({
      title: '清空全部数据',
      message: '将删除本机全部班表/课表/计划/窗口/伴侣档案与设置项，且不可恢复。确定清空？',
      primaryButton: {
        value: '取消',
        action: () => {
        }
      },
      secondaryButton: {
        value: '清空',
        fontColor: $r('app.color.danger_red'),
        action: () => this.doClearAll()
      }
    });
  }

  async doClearAll(): Promise<void> {
    this.clearing = true;
    try {
      // 周摘要提醒先在系统侧取消（设置即将被清，id 先取出）
      const weeklyId = await SettingsStore.getWeeklyReminderId();
      if (weeklyId >= 0) {
        try {
          await reminderAgentManager.cancelReminder(weeklyId);
        } catch (e) {
          // 提醒已被系统清理：忽略
        }
      }
      const privacyWas = SettingsStore.isPrivacyAccepted();
      await ScheduleRepo.clearAllData();
      await SettingsStore.clearAllSettings();
      if (privacyWas) {
        await SettingsStore.acceptPrivacy();
      }
      await ScheduleUseCase.onScheduleChanged();
      this.pairState = PAIR_NONE;
      this.myCode = '';
      this.reload();
      promptAction.showToast({ message: '已清空全部数据' });
    } catch (e) {
      promptAction.showToast({ message: '清空失败：' + (e as Error).message });
    }
    this.clearing = false;
  }

  // ---------- 我的引擎参数（起床/就寝/收整/视界） ----------

  reloadMyParams(): void {
    try {
      const p = SettingsStore.getParams();
      if (!this.myEditing) {
        this.myWake = minToHHmm(p.wakeMin);
        this.myBed = minToHHmm(p.bedMin);
        this.myWind = '' + p.windDownMin;
        this.myHorizon = '' + p.horizonDays;
      }
    } catch (e) {
      // Settings 未初始化时保持默认
    }
  }

  startEditMyParams(): void {
    this.reloadMyParams();
    this.myEditing = true;
  }

  cancelMyEdit(): void {
    this.myEditing = false;
    this.reloadMyParams();
  }

  saveMyParams(): void {
    const wake = hhmmToMin(this.myWake);
    const bed = hhmmToMin(this.myBed);
    const wind = this.toInt(this.myWind, -1);
    const horizon = this.toInt(this.myHorizon, -1);
    if (wake < 0 || bed < 0) {
      promptAction.showToast({ message: '时间格式应为 HH:MM（如 07:00）' });
      return;
    }
    if (bed <= wake) {
      promptAction.showToast({ message: '就寝时间需晚于起床时间' });
      return;
    }
    if (wind < 0) {
      promptAction.showToast({ message: '收整缓冲不能为负' });
      return;
    }
    if (horizon < 7 || horizon > 366) {
      promptAction.showToast({ message: '视界天数需在 7–366 天之间' });
      return;
    }
    const p: EngineParams = SettingsStore.getParams();
    p.wakeMin = wake;
    p.bedMin = bed;
    p.windDownMin = wind;
    p.horizonDays = horizon;
    SettingsStore.setParams(p).then(() => {
      return ScheduleUseCase.onScheduleChanged();
    }).then(() => {
      this.myEditing = false;
      this.reloadMyParams();
      promptAction.showToast({ message: '参数已保存，已重新计算' });
    }).catch((e: Error) => {
      promptAction.showToast({ message: '保存失败：' + e.message });
    });
  }

  build() {
    Scroll() {
      Column({ space: 12 }) {
        // 个人卡：渐变底 + 头像占位 + 配对状态
        Row({ space: 14 }) {
          Column() {
            Text('我').fontSize(18).fontWeight(FontWeight.Bold).fontColor('#FFFFFF')
          }
          .width(52).height(52).justifyContent(FlexAlign.Center)
          .borderRadius(26)
          .backgroundColor('#33FFFFFF')

          Column({ space: 3 }) {
            Text('我的').fontSize(20).fontWeight(FontWeight.Bold).fontColor('#FFFFFF')
            Text(this.pairStateText() + (this.partnerExists ? ' · 与 ' + this.pNick : ''))
              .fontSize(12).fontColor('#FFFFFFB8')
          }.alignItems(HorizontalAlign.Start).layoutWeight(1)

          SymbolGlyph($r('sys.symbol.heart'))
            .fontSize(24).fontColor(['#FFFFFF'])
        }
        .width('100%')
        .padding(20)
        .borderRadius(24)
        .linearGradient({
          angle: 135,
          colors: [[$r('app.color.sunset_from'), 0], [$r('app.color.sunset_to'), 1]]
        })
        .shadow({ radius: 16, color: $r('app.color.shadow_soft'), offsetX: 0, offsetY: 4 })
        .margin({ top: 16 })

        this.partnerCard()

        this.pairingCard()

        this.myParamsCard()

        this.shareLevelCard()

        this.settingsCard()
      }
      .padding(16).width('100%')
    }
    .width('100%').height('100%').align(Alignment.Top)
    .backgroundColor($r('app.color.page_bg_warm'))
  }

  /** 云端配对卡片：未配对（生成邀请码/输码加入）→ 等待对方加入（展示配对码）→ 已配对（解除配对）。 */
  @Builder
  pairingCard() {
    Column({ space: 10 }) {
      Row() {
        Text('云端配对').fontSize(15).fontWeight(FontWeight.Medium)
        Blank()
        Text(this.pairStateText()).fontSize(12)
          .fontColor(this.pairState === PAIRED ? $r('app.color.brand_pink') : $r('app.color.text_tertiary'))
          .padding({ left: 10, right: 10, top: 3, bottom: 3 })
          .borderRadius(10)
          .backgroundColor(this.pairState === PAIRED
            ? $r('app.color.brand_pink_bg') : $r('app.color.fill_weakest'))
      }.width('100%')

      if (this.pairState === PAIRED) {
        Text('已与另一台设备配对：班表变更会按你的隐私等级加密后同步给 TA。')
          .fontSize(12).fontColor($r('app.color.text_tertiary'))
        Button('解除配对').width('100%')
          .backgroundColor($r('app.color.fill_weak')).fontColor($r('app.color.danger_red'))
          .onClick(() => this.askUnpair())
      } else if (this.pairState === PAIR_WAITING) {
        if (this.myCode !== '') {
          // 配对码二维码（黑白固定对比色，不随深浅色反转，保证扫码可读）
          Row() {
            QRCode(this.myCode)
              .width(128)
              .height(128)
              .color('#1A1A1A')
              .backgroundColor('#FFFFFF')
              .padding(10)
              .borderRadius(8)
          }.width('100%').justifyContent(FlexAlign.Center)
          Text(this.myCode).fontSize(34).fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.brand_pink')).width('100%').textAlign(TextAlign.Center)
            .letterSpacing(6)
          Text('扫码或把配对码发给 TA，在 TA 的「我的 → 云端配对」中输入即可完成配对。')
            .fontSize(11).fontColor($r('app.color.text_hint')).textAlign(TextAlign.Center).width('100%')
        } else {
          Text('配对码已生成（本次进入页面未显示）。如对方未收到，可重新生成。')
            .fontSize(11).fontColor($r('app.color.text_hint'))
        }
        Row({ space: 10 }) {
          Button('完成配对').layoutWeight(1)
            .backgroundColor($r('app.color.brand_pink'))
            .onClick(() => this.markPaired())
          Button('取消配对').layoutWeight(1)
            .backgroundColor($r('app.color.btn_neutral'))
            .onClick(() => this.cancelWaiting())
        }.width('100%')
        Text('体验版无服务端推送：对方输码加入后，在这里点「完成配对」即开始加密同步。')
          .fontSize(10).fontColor($r('app.color.text_hint'))
      } else {
        Text('两台手机异地配对：一端生成配对码，另一端输入后，班表按隐私等级加密同步。')
          .fontSize(12).fontColor($r('app.color.text_tertiary'))
        Row({ space: 10 }) {
          Button(this.pairingBusy ? '生成中…' : '生成邀请码').layoutWeight(1)
            .backgroundColor($r('app.color.brand_pink'))
            .enabled(!this.pairingBusy)
            .onClick(() => this.createInvite())
          Button('输码加入').layoutWeight(1)
            .backgroundColor($r('app.color.btn_neutral'))
            .enabled(!this.pairingBusy)
            .onClick(() => {
              this.showJoinInput = !this.showJoinInput;
            })
        }.width('100%')

        if (this.showJoinInput) {
          Row({ space: 8 }) {
            Text('配对码').fontSize(13)
            TextInput({ text: this.joinCode, placeholder: '6 位数字' })
              .layoutWeight(1).height(38)
              .type(InputType.Number)
              .maxLength(6)
              .onChange((v: string) => this.joinCode = v)
            Button(this.pairingBusy ? '加入中…' : '加入')
              .backgroundColor($r('app.color.brand_pink'))
              .enabled(!this.pairingBusy)
              .onClick(() => this.joinByCode())
          }.width('100%')
        }

        Text('需开通 AGC 云服务；未开通时会提示并保持本机代录可用。')
          .fontSize(11).fontColor($r('app.color.text_hint'))
      }
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%').padding(16).borderRadius(20)
    .backgroundColor($r('app.color.card_bg'))
    .shadow({ radius: 16, color: $r('app.color.shadow_soft'), offsetX: 0, offsetY: 4 })
  }

  /** 设置卡片：隐私政策入口 + 清空全部数据。 */
  @Builder
  settingsCard() {
    Column({ space: 10 }) {
      Text('数据与隐私').fontSize(15).fontWeight(FontWeight.Medium)

      Row() {
        Text('隐私政策').fontSize(14)
        Blank()
        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(16).fontColor([$r('app.color.text_hint')])
      }
      .width('100%').padding({ top: 8, bottom: 8 })
      .onClick(() => {
        const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
        openPrivacyPolicy(ctx, $r('app.string.privacy_fulltext_soon'));
      })

      Divider().color($r('app.color.fill_weak'))

      Row() {
        Column({ space: 2 }) {
          Text('清空我的全部数据').fontSize(14).fontColor($r('app.color.danger_red'))
          Text('删除本机全部班表/课表/计划与设置，不可恢复')
            .fontSize(11).fontColor($r('app.color.text_hint'))
        }.alignItems(HorizontalAlign.Start)
        Blank()
        if (this.clearing) {
          Text('清空中…').fontSize(13).fontColor($r('app.color.text_hint'))
        } else {
          SymbolGlyph($r('sys.symbol.chevron_right'))
            .fontSize(16).fontColor([$r('app.color.text_hint')])
        }
      }
      .width('100%').padding({ top: 8, bottom: 8 })
      .onClick(() => this.askClearAll())
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%').padding(16).borderRadius(20)
    .backgroundColor($r('app.color.card_bg'))
    .shadow({ radius: 16, color: $r('app.color.shadow_soft'), offsetX: 0, offsetY: 4 })
  }

  /** 我的作息参数卡片：只读摘要 / 编辑表单（保存后持久化并触发重算）。 */
  @Builder
  myParamsCard() {
    Column({ space: 10 }) {
      Row() {
        Text('我的作息参数').fontSize(15).fontWeight(FontWeight.Medium)
        Blank()
        if (!this.myEditing) {
          Text('编辑').fontSize(13).fontColor($r('app.color.brand_pink'))
            .onClick(() => this.startEditMyParams())
        }
      }.width('100%')

      if (this.myEditing) {
        Column({ space: 8 }) {
          Row({ space: 8 }) {
            Text('起床').fontSize(13)
            TextInput({ text: this.myWake }).width(64).height(38)
              .onChange((v: string) => this.myWake = v)
            Text('就寝').fontSize(13)
            TextInput({ text: this.myBed }).width(64).height(38)
              .onChange((v: string) => this.myBed = v)
            Text('收整(分)').fontSize(13)
            TextInput({ text: this.myWind }).width(56).height(38)
              .onChange((v: string) => this.myWind = v)
          }.width('100%')
          Row({ space: 8 }) {
            Text('计算视界(天)').fontSize(13)
            TextInput({ text: this.myHorizon }).width(64).height(38)
              .onChange((v: string) => this.myHorizon = v)
            Text('未来多少天参与计算（7–366）').fontSize(11).fontColor($r('app.color.text_hint'))
          }.width('100%')
          Row({ space: 10 }) {
            Button('保存').layoutWeight(1).backgroundColor($r('app.color.brand_pink'))
              .onClick(() => this.saveMyParams())
            Button('取消').layoutWeight(1).backgroundColor($r('app.color.btn_neutral'))
              .onClick(() => this.cancelMyEdit())
          }.width('100%')
        }
        .width('100%')
      } else {
        Text('起床 ' + this.myWake + ' · 就寝 ' + this.myBed + ' · 收整缓冲 ' + this.myWind
          + ' 分钟 · 视界 ' + this.myHorizon + ' 天')
          .fontSize(12).fontColor($r('app.color.text_tertiary'))
        Text('这些参数决定你的睡眠与收整如何参与共同时间计算（默认：起床 07:00 · 就寝 22:30 · 收整 20 分 · 视界 '
          + AppConst.HORIZON_DAYS + ' 天）。')
          .fontSize(11).fontColor($r('app.color.text_hint'))
      }
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%').padding(16).borderRadius(20)
    .backgroundColor($r('app.color.card_bg'))
    .shadow({ radius: 16, color: $r('app.color.shadow_soft'), offsetX: 0, offsetY: 4 })
  }

  /** 伴侣档案卡片：无伴侣→添加入口；有伴侣→昵称+参数+编辑/删除；编辑态→表单。 */
  @Builder
  partnerCard() {
    Column({ space: 10 }) {
      Text('伴侣（本机代录）').fontSize(15).fontWeight(FontWeight.Medium)

      if (this.partnerEditing) {
        Column({ space: 8 }) {
          Row({ space: 8 }) {
            Text('昵称').fontSize(13)
            TextInput({ text: this.pNick, placeholder: 'TA 的昵称（如：阿明）' })
              .layoutWeight(1).height(38)
              .onChange((v: string) => this.pNick = v)
          }.width('100%')
          Row({ space: 8 }) {
            Text('起床').fontSize(13)
            TextInput({ text: this.pWake }).width(64).height(38)
              .onChange((v: string) => this.pWake = v)
            Text('就寝').fontSize(13)
            TextInput({ text: this.pBed }).width(64).height(38)
              .onChange((v: string) => this.pBed = v)
            Text('收整(分)').fontSize(13)
            TextInput({ text: this.pWind }).width(56).height(38)
              .onChange((v: string) => this.pWind = v)
          }.width('100%')
          Text('作息格式 HH:MM。TA 的起床/就寝/收整独立参与共同时间计算。')
            .fontSize(11).fontColor($r('app.color.text_hint'))
          Row({ space: 10 }) {
            Button('保存').layoutWeight(1).backgroundColor($r('app.color.brand_pink'))
              .onClick(() => this.savePartner())
            Button('取消').layoutWeight(1).backgroundColor($r('app.color.btn_neutral'))
              .onClick(() => this.cancelPartnerEdit())
          }.width('100%')
        }
        .width('100%')
      } else if (!this.partnerExists) {
        Text('还没有伴侣。添加后可在这台手机上代录 TA 的课表/班表，自动算出你们的共同时间。')
          .fontSize(12).fontColor($r('app.color.text_tertiary'))
        Button('添加伴侣（本机代录）').width('100%').backgroundColor($r('app.color.brand_pink'))
          .onClick(() => this.startAddPartner())
      } else {
        Row() {
          Column({ space: 4 }) {
            Text(this.pNick).fontSize(16).fontWeight(FontWeight.Medium)
            Text('起床 ' + this.pWake + ' · 就寝 ' + this.pBed + ' · 收整 ' + this.pWind + ' 分钟')
              .fontSize(12).fontColor($r('app.color.text_tertiary'))
          }.alignItems(HorizontalAlign.Start)
          Blank()
          Text('编辑').fontSize(13).fontColor($r('app.color.brand_pink'))
            .onClick(() => this.startEditPartner())
          Text('删除').fontSize(13).fontColor($r('app.color.danger_red')).margin({ left: 14 })
            .onClick(() => this.confirmDeletePartner())
        }.width('100%')
        Text('为 TA 录入课表/班表请到「班表」页切换到伴侣侧。')
          .fontSize(11).fontColor($r('app.color.text_hint'))
      }
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%').padding(16).borderRadius(20)
    .backgroundColor($r('app.color.card_bg'))
    .shadow({ radius: 16, color: $r('app.color.shadow_soft'), offsetX: 0, offsetY: 4 })
  }

  levelText(): string {
    if (this.shareLevel === 1) {
      return 'L1 仅忙闲状态';
    }
    if (this.shareLevel === 2) {
      return 'L2 班次类型（默认推荐）';
    }
    return 'L3 完整上下班时间';
  }

  // ---------- 隐私共享等级（L1/L2/L3 切换 + 持久化） ----------

  /** 各等级"对方可见内容"对照说明。 */
  levelDesc(level: number): string {
    if (level === 1) {
      return '对方只见你有空/忙碌，看不到原因与具体时间';
    }
    if (level === 2) {
      return '对方可见忙碌类型（如上课/上班），不含精确时段';
    }
    return '对方可见完整忙碌时段，共同时间计算最精准';
  }

  levelTitle(level: number): string {
    if (level === 1) {
      return 'L1 忙闲状态';
    }
    if (level === 2) {
      return 'L2 班次类型';
    }
    return 'L3 完整时间';
  }

  /** 切换等级：持久化 + 触发重算（等级参与快照生成）。 */
  pickLevel(level: number): void {
    if (this.shareLevel === level) {
      return;
    }
    this.shareLevel = level;
    SettingsStore.setShareLevel(level).then(() => {
      return ScheduleUseCase.onScheduleChanged();
    }).then(() => {
      promptAction.showToast({ message: '已切换到' + this.levelTitle(level) + '，重启后仍保持' });
    }).catch((e: Error) => {
      promptAction.showToast({ message: '保存失败：' + e.message });
    });
  }

  /** 隐私等级卡片：三级单选列表 + 每级"对方可见内容"说明。 */
  @Builder
  shareLevelCard() {
    Column({ space: 10 }) {
      Text('隐私共享等级').fontSize(15).fontWeight(FontWeight.Medium)
      Text('决定云端配对后对方能看到什么。当前本机代录模式下用于生成共享快照，本机仍显示双方完整数据。')
        .fontSize(11).fontColor($r('app.color.text_hint'))

      ForEach([1, 2, 3], (lv: number) => {
        Row({ space: 10 }) {
          Radio({ value: '' + lv, group: 'shareLevel' })
            .checked(this.shareLevel === lv)
            .onChange((checked: boolean) => {
              if (checked) {
                this.pickLevel(lv);
              }
            })
          Column({ space: 3 }) {
            Row({ space: 6 }) {
              Text(this.levelTitle(lv)).fontSize(14)
                .fontColor(this.shareLevel === lv ? $r('app.color.brand_pink') : $r('app.color.text_primary'))
                .fontWeight(this.shareLevel === lv ? FontWeight.Medium : FontWeight.Normal)
              if (lv === 2) {
                Text('默认').fontSize(10).fontColor('#FFFFFF')
                  .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                  .borderRadius(8).backgroundColor($r('app.color.brand_pink'))
              }
            }.alignItems(VerticalAlign.Center)
            Text(this.levelDesc(lv)).fontSize(11).fontColor($r('app.color.text_tertiary'))
          }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        }
        .width('100%')
        .padding({ top: 8, bottom: 8 })
        .borderRadius(10)
        .backgroundColor(this.shareLevel === lv ? $r('app.color.brand_pink_bg') : $r('app.color.fill_weakest'))
        .onClick(() => this.pickLevel(lv))
      }, (lv: number) => 'lv' + lv)
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%').padding(16).borderRadius(20)
    .backgroundColor($r('app.color.card_bg'))
    .shadow({ radius: 16, color: $r('app.color.shadow_soft'), offsetX: 0, offsetY: 4 })
  }
}
