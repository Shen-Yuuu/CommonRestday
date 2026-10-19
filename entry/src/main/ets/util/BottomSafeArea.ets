import { window } from '@kit.ArkUI';

/** Main-window gesture/navigation inset, in vp. Sheets own their own content padding. */
function onBottomAvoidAreaChanged(options: window.AvoidAreaOptions): void {
  if (options.type === window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR
    || options.type === window.AvoidAreaType.TYPE_SYSTEM) BottomSafeArea.refresh();
}
function onWindowSizeChanged(): void { BottomSafeArea.refresh(); }

export class BottomSafeArea {
  private static host: window.Window | undefined = undefined;
  static attach(host: window.Window): void {
    BottomSafeArea.detach();
    BottomSafeArea.host = host;
    BottomSafeArea.refresh();
    try { host.on('avoidAreaChange', onBottomAvoidAreaChanged); } catch { /* Keep the last measured inset. */ }
    try { host.on('windowSizeChange', onWindowSizeChanged); } catch { /* Foreground refresh also measures height. */ }
  }
  static refresh(): void {
    const host = BottomSafeArea.host;
    if (host === undefined) return;
    try {
      const gesture = host.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR).bottomRect.height;
      const system = host.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM).bottomRect.height;
      const inset = Math.max(0, host.getUIContext().px2vp(Math.max(gesture, system)));
      if (Number.isFinite(inset)) AppStorage.setOrCreate<number>('crd_bottom_safe_vp', inset);
    } catch { /* Default 16vp + footer gap remains safe when measurement is unavailable. */ }
    try {
      const height = host.getUIContext().px2vp(host.getWindowProperties().windowRect.height);
      if (Number.isFinite(height) && height > 0) AppStorage.setOrCreate<number>('crd_window_height_vp', height);
    } catch { /* The editor has a bounded fallback before the window is ready. */ }
  }
  static detach(): void {
    const host = BottomSafeArea.host;
    BottomSafeArea.host = undefined;
    if (host !== undefined) {
      try { host.off('avoidAreaChange', onBottomAvoidAreaChanged); } catch { /* Window may already be destroyed. */ }
      try { host.off('windowSizeChange', onWindowSizeChanged); } catch { /* Window may already be destroyed. */ }
    }
  }
}
