import auth from '@hw-agconnect/auth';
import { cloudFunction } from '@kit.CloudFoundationKit';
import { BusinessError } from '@kit.BasicServicesKit';

interface IdentityReceipt {
  code: string;
  authenticated: boolean;
  subjectFingerprint: string;
  sharedPlanReady: boolean;
  message: string;
}

interface CasLegReceipt {
  state: string;
  outcome: string;
  readVersions: number[];
}

interface CasReceipt {
  code: string;
  probeId: string;
  legs: CasLegReceipt[];
  finalVersion: number;
  finalState: string;
  overlapObserved: boolean;
  sharedPlanReady: boolean;
  message: string;
}

/** Mount ONLY inside the disposable CloudDevSpikeOfficial test application. */
@Component
export struct SharedPlanPreflightPanel {
  @State busy: boolean = false;
  @State receipt: string = '尚未验证。此页不读取正式应用的配对或日程。';

  private async token(): Promise<string> {
    let user = await auth.getCurrentUser();
    if (user === null) user = (await auth.signInAnonymously()).getUser();
    if (!user.isAnonymous()) throw new Error('隔离工程当前不是匿名测试身份');
    return (await user.getToken(true)).getString();
  }

  private async inspectIdentity(useInvalidToken: boolean): Promise<void> {
    if (this.busy) return;
    this.busy = true;
    this.receipt = '正在验证身份…';
    try {
      const token = useInvalidToken ? 'invalid-preflight-token' : await this.token();
      const reply = await cloudFunction.call({ name: 'sharedplanpreflight', version: '$latest',
        data: { method: 'verifyIdentity', params: [token] } });
      const result = reply.result as IdentityReceipt;
      this.receipt = 'code: ' + result.code + '\n认证通过: ' + result.authenticated
        + '\n主体指纹: ' + result.subjectFingerprint + '\n' + result.message;
    } catch (error) {
      const failure = error as BusinessError;
      this.receipt = '身份调用未完成，错误码 ' + failure.code + '。不要粘贴访问令牌。';
    } finally { this.busy = false; }
  }

  private async inspectRace(): Promise<void> {
    if (this.busy) return;
    this.busy = true;
    this.receipt = '正在执行独立事务竞争…';
    try {
      const token = await this.token();
      const reply = await cloudFunction.call({ name: 'sharedplanpreflight', version: '$latest',
        data: { method: 'runRace', params: [token] } });
      const result = reply.result as CasReceipt;
      this.receipt = 'code: ' + result.code + '\n测试行: ' + result.probeId
        + '\n重叠读取: ' + result.overlapObserved + '\n最终: ' + result.finalVersion + ' / ' + result.finalState
        + '\n两请求: ' + JSON.stringify(result.legs) + '\n' + result.message;
    } catch (error) {
      const failure = error as BusinessError;
      this.receipt = '事务调用未完成，错误码 ' + failure.code + '。不能判通过。';
    } finally { this.busy = false; }
  }

  build() {
    Column({ space: 12 }) {
      Text('共同计划前置验证').fontSize(20).fontWeight(FontWeight.Bold)
      Button('1 · 验证匿名身份').enabled(!this.busy).onClick(() => this.inspectIdentity(false))
      Button('2 · 验证错误令牌被拒绝').enabled(!this.busy).onClick(() => this.inspectIdentity(true))
      Button('3 · 验证两个事务只能提交一个').enabled(!this.busy).onClick(() => this.inspectRace())
      Text(this.receipt).fontSize(14).width('100%')
      Text('仅测试隔离工程；不会开启正式应用共同计划或通知。').fontSize(12)
    }.width('100%').padding(16)
  }
}
