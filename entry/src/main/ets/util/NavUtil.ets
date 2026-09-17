/**
 * 跨 Tab 导航广播：「我的」/「共同」页切换请求。
 * 页面/视图内无法直接操作 Index 的 Tabs，用 AppStorage 计数广播，
 * Index 通过 @StorageProp + @Watch 监听并切换 activeTab。
 */
export const NAV_TO_ME_KEY = 'navToMeCount';
export const NAV_TO_COTIME_KEY = 'navToCoTimeCount';

/** 请求切换到「我的」Tab（添加伴侣引导等入口使用）。 */
export function navToMe(): void {
  const cur: number = AppStorage.get<number>(NAV_TO_ME_KEY) ?? 0;
  AppStorage.setOrCreate<number>(NAV_TO_ME_KEY, cur + 1);
}

/** 请求切换到「共同」Tab（计划页空态引导"去共同时间页选一个窗口"使用）。 */
export function navToCoTime(): void {
  const cur: number = AppStorage.get<number>(NAV_TO_COTIME_KEY) ?? 0;
  AppStorage.setOrCreate<number>(NAV_TO_COTIME_KEY, cur + 1);
}
