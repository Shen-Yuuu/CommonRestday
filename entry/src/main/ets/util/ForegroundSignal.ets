/** 装饰动画只在应用前台运行；不涉及同步、计时或后台任务。 */
export function publishForeground(active: boolean): void {
  AppStorage.setOrCreate<boolean>('crd_app_foreground', active);
}
