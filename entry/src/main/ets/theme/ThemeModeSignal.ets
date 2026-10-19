/** UIAbility 收到的系统颜色模式；只广播 UI 配置，不触发日程重算或云同步。 */
export const COLOR_MODE_KEY: string = 'crd_color_mode';

/** 相同模式不重复派发；新页面仍会在 aboutToAppear 按当前资源建自己的组件。 */
export function publishColorMode(mode: number | undefined): void {
  if (mode === undefined || AppStorage.get<number>(COLOR_MODE_KEY) === mode) {
    return;
  }
  AppStorage.setOrCreate<number>(COLOR_MODE_KEY, mode);
}
