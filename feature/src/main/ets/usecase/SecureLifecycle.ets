/** In-process fence for asynchronous setup started before/during a user-requested local clear. */
export class SecureLifecycle {
  private static clearing: number = 0;
  private static epoch: number = 0;
  private static cleanup: () => Promise<void> = () => Promise.resolve();
  private static disconnect: () => Promise<string> = () => Promise.resolve('OK');
  static installDisconnect(work: () => Promise<string>): void { SecureLifecycle.disconnect = work; }
  static disconnectPlans(): Promise<string> { return SecureLifecycle.disconnect(); }
  static installCleanup(work: () => Promise<void>): void { SecureLifecycle.cleanup = work; }
  static clearLocalKeys(): Promise<void> { return SecureLifecycle.cleanup(); }
  static blocked(): boolean { return SecureLifecycle.clearing > 0; }
  static anchor(): string { return String(SecureLifecycle.epoch); }
  /** Cancel in-flight setup without disabling the authenticated cleanup path. */
  static invalidate(): void { SecureLifecycle.epoch++; }
  static beginClear(): void { SecureLifecycle.clearing++; SecureLifecycle.epoch++; }
  static endClear(): void { SecureLifecycle.clearing = Math.max(0, SecureLifecycle.clearing - 1); }
}
