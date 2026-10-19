import { PAIRED, PAIR_PENDING, SettingsStore } from 'data';
import { FeatureFlags, ProfileSettingsService, unifiedPairing, UnifiedPairingResult } from 'feature';
import { DesignTokens } from '../theme/DesignTokens';
import { LatestLanding } from '../util/LatestLanding';

/** One status inside cloud pairing. Bounded foreground setup checks, never background polling. */
@Component
export struct UnifiedPairingStatus {
  @Prop @Watch('visibilityChanged') active: boolean = true;
  @Prop @Watch('visibilityChanged') legacyState: string = '';
  @StorageProp('crd_app_foreground') @Watch('visibilityChanged') foreground: boolean = true;
  onState: (phase: string) => void = (_phase: string): void => {};
  @State private phase: string = 'CONNECTING';
  @State private code: string = 'OK';
  @State private busy: boolean = false;
  private mounted: boolean = false;
  private timer: number = -1;
  private generation: number = 0;
  private landing: LatestLanding = new LatestLanding();
  private deadline: number = 0;
  aboutToAppear(): void { this.mounted = true; this.visibilityChanged(); }
  aboutToDisappear(): void { this.mounted = false; this.stop(); }
  private stop(): void {
    this.generation++;
    this.landing.invalidate();
    if (this.timer >= 0) clearTimeout(this.timer);
    this.timer = -1;
  }
  visibilityChanged(): void {
    this.stop();
    if (!this.mounted || !this.active || !this.foreground) return;
    this.deadline = Date.now() + 60000;
    this.check(false);
  }
  private async check(consent: boolean): Promise<void> {
    if (this.busy || !this.mounted || !this.active || !this.foreground) return;
    const generation = this.generation;
    const token = this.landing.begin();
    this.busy = true;
    let next: UnifiedPairingResult = { code: 'OK', phase: 'NOT_PAIRED' };
    try {
      // The joiner observes the inviter's one confirmation without entering a second code.
      if (SettingsStore.getPairState() === PAIR_PENDING && !ProfileSettingsService.hasLocalInviteProof()) {
        const reconciled = await ProfileSettingsService.reconcilePair();
        if (!reconciled.ok) next = { code: 'RESULT_UNKNOWN', phase: 'FAILED' };
      }
      if (!this.landing.isCurrent(token) || generation !== this.generation || !this.mounted || !this.active || !this.foreground) return;
      if (next.code === 'OK' && SettingsStore.getPairState() === PAIRED) next = await unifiedPairing().advance(consent);
      if (!this.landing.isCurrent(token) || generation !== this.generation || !this.mounted || !this.active || !this.foreground) return;
      this.phase = next.phase; this.code = next.code; this.onState(next.phase);
      const waiting = next.phase === 'WAITING' || next.phase === 'CONNECTING'
        || (next.phase === 'NOT_PAIRED' && SettingsStore.getPairState() === PAIR_PENDING);
      if (next.code === 'OK' && waiting && Date.now() < this.deadline) {
        this.timer = setTimeout(() => {
          this.timer = -1;
          if (Date.now() < this.deadline) this.check(false);
        }, 3000);
      }
    } catch {
      if (this.landing.isCurrent(token) && generation === this.generation && this.mounted) {
        this.phase = 'FAILED'; this.code = 'RESULT_UNKNOWN'; this.onState('FAILED');
      }
    } finally {
      this.busy = false;
      // A visibility/state change during an in-flight request starts one new bounded check.
      if (generation !== this.generation && this.mounted && this.active && this.foreground) this.check(false);
    }
  }
  private message(): string {
    if (this.phase === 'READY') return '班表同步 · 共同计划均已连接';
    if (this.phase === 'UPGRADE') return '双方点「完成连接」即可使用共同计划，无需再次输码。';
    if (this.phase === 'WAITING') return '正在连接，请让 TA 保持应用打开。';
    if (this.phase === 'FAILED') {
      if (this.code === 'FEATURE_DISABLED') return '共同计划连接暂不可用，请确认云端已更新，当前配对和数据已保留。';
      if (this.code === 'CODE_EXPIRED') return '这次连接交接已过期，原配对和数据已保留，请检查连接状态。';
      if (this.code === 'CLEANUP_PENDING' || this.code === 'CLEANUP_REQUIRED') return '原连接仍有清理待完成，请到数据与隐私继续清理。';
      if (this.code === 'PARTNER_LINK_REQUIRED' || this.code === 'SESSION_CHANGED') return '伴侣或设备校验未通过，原连接没有被替换。';
      if (this.code === 'CODE_COLLISION') return '检测到多份未完成连接，未自动替换。请双方核对原连接后继续。';
      return '连接尚未完成，进度已保留。检查网络后点「继续连接」。';
    }
    return '正在连接班表与共同计划…';
  }
  build() {
    if (this.legacyState === PAIRED && FeatureFlags.cloudPairing) {
      Column({ space: 10 }) {
        Text(this.message()).fontSize(DesignTokens.fontCaption).fontColor(DesignTokens.textSecondary).width('100%')
        if (this.phase !== 'READY') {
          Button(this.busy ? '连接中…' : (this.phase === 'UPGRADE' ? '完成连接' : '继续连接'))
            .width('100%').constraintSize({ minHeight: 44 }).stateEffect(false)
            .fontSize(DesignTokens.fontBody).backgroundColor(DesignTokens.primaryBg).fontColor(DesignTokens.textAccent)
            .enabled(!this.busy).onClick(() => {
              this.stop(); this.deadline = Date.now() + 60000; this.check(true);
            })
        }
      }.width('100%').alignItems(HorizontalAlign.Start)
    }
  }
}
