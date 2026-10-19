import auth from '@hw-agconnect/auth';
import { cloudFunction } from '@kit.CloudFoundationKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { util } from '@kit.ArkTS';

interface ProbePlan {
  planId: string;
  state: string;
  stateVersion: number;
  contentRevision: number;
  acceptedRevision: number;
  pendingAuthorUid: string;
}
interface ProbeReply {
  code: string;
  message?: string;
  pairId?: string;
  status?: string;
  myUid?: string;
  peerUid?: string;
  inviteCode?: string;
  confirmSecret?: string;
  plan?: ProbePlan;
  plans?: ProbePlan[];
}
interface ProbeCommand {
  pairId: string;
  planId: string;
  requestId: string;
  action: string;
  expectedVersion: number;
  envelope: string;
}
interface ProbeEnvelope {
  protocolVersion: number;
  contentRevision: number;
  algorithm: string;
  iv: string;
  authTag: string;
  ciphertext: string;
}

// Public curve generator point, NOT a device key; encrypted-format fixtures carry no user data.
const FIXTURE_PUBLIC_KEY: string = 'BGsX0fLhLEJH+Lzm5WOkQPJ3A32BLeszoPShOUXYmMKWT+NC4v4af5uO5+tKfA+eFivOM1drMV7Oy7ZAaDe/UfU=';

@Component
export struct SecureSharedPlanPanel {
  @State busy: boolean = false;
  @State inviteInput: string = '';
  @State inviteCode: string = '';
  @State pairId: string = '';
  @State pairStatus: string = '';
  @State planId: string = 'demo-plan-1';
  @State planVersion: number = 0;
  @State contentRevision: number = 0;
  @State plans: ProbePlan[] = [];
  @State receipt: string = '仅测试隔离安全会话；不是正式日程，也不会发送通知。';
  @State retryPending: boolean = false;
  private createRequestId: string = util.generateRandomUUID();
  private confirmSecret: string = '';
  private pendingCommand: string = '';

  private async token(): Promise<string> {
    let user = await auth.getCurrentUser();
    if (user === null) user = (await auth.signInAnonymously()).getUser();
    if (!user.isAnonymous()) throw new Error('需要隔离匿名测试身份');
    return (await user.getToken(true)).getString();
  }

  private choose(row: ProbePlan): void {
    if (row.planId === this.planId && row.stateVersion < this.planVersion) return;
    this.planId = row.planId;
    this.planVersion = row.stateVersion;
    this.contentRevision = row.contentRevision;
  }

  private async invoke(method: string, params: Object[]): Promise<void> {
    if (this.busy) return;
    this.busy = true;
    this.receipt = '正在调用 ' + method + '…';
    try {
      const args: Object[] = [await this.token()];
      for (const param of params) args.push(param);
      const response = await cloudFunction.call({ name: 'dateplan', version: '$latest',
        data: { method: method, params: args } });
      const encoded = typeof response.result === 'string' ? response.result : JSON.stringify(response.result);
      const result = JSON.parse(encoded) as ProbeReply;
      if (result.code === 'OK') {
        if (result.pairId !== undefined) this.pairId = result.pairId;
        if (result.status !== undefined) this.pairStatus = result.status;
        if (result.inviteCode !== undefined) this.inviteCode = result.inviteCode;
        if (result.confirmSecret !== undefined) this.confirmSecret = result.confirmSecret;
        if (result.plan !== undefined) this.choose(result.plan);
        if (result.plans !== undefined) {
          this.plans = result.plans;
          const selected = result.plans.find((item: ProbePlan) => item.planId === this.planId);
          if (selected !== undefined) this.choose(selected);
          else if (result.plans.length > 0) this.choose(result.plans[0]);
        }
        if (method === 'mutate') { this.pendingCommand = ''; this.retryPending = false; }
      } else if (method === 'mutate' && result.code !== 'RESULT_UNKNOWN') {
        this.pendingCommand = ''; this.retryPending = false;
      }
      // Never render the token, confirmation proof, keys, or encrypted payload.
      this.receipt = 'code: ' + result.code + '\n会话: ' + (result.status ?? this.pairStatus)
        + '\n计划: ' + (result.plan?.planId ?? this.planId)
        + '\n状态: ' + (result.plan?.state ?? '请看下方列表')
        + '\n版本: ' + (result.plan?.stateVersion ?? this.planVersion)
        + '\n内容 / 已确认修订: ' + (result.plan?.contentRevision ?? this.contentRevision)
        + ' / ' + (result.plan?.acceptedRevision ?? '见列表')
        + '\n' + (result.message ?? '');
    } catch (error) {
      const failure = error as BusinessError;
      this.receipt = '调用未完成，错误码 ' + failure.code + '。保留原请求，不要贴访问令牌。';
    } finally { this.busy = false; }
  }

  private fixture(revision: number): string {
    const envelope: ProbeEnvelope = { protocolVersion: 1, contentRevision: revision, algorithm: 'AES-256-GCM',
      iv: 'AQEBAQEBAQEBAQEB', authTag: 'AgICAgICAgICAgICAgICAg==', ciphertext: 'cHJvYmU=' };
    return JSON.stringify(envelope);
  }

  private send(action: string): void {
    if (this.busy || this.retryPending) return;
    const command: ProbeCommand = { pairId: this.pairId, planId: this.planId,
      requestId: util.generateRandomUUID(), action: action,
      expectedVersion: action === 'PROPOSE' ? 0 : this.planVersion,
      envelope: action === 'PROPOSE' ? this.fixture(1) : action === 'AMEND' ? this.fixture(this.contentRevision + 1) : '' };
    this.pendingCommand = JSON.stringify(command);
    this.retryPending = true;
    this.invoke('mutate', [this.pendingCommand]);
  }

  build() {
    Column({ space: 12 }) {
      Text('安全配对与共同计划验证').fontSize(20).fontWeight(FontWeight.Bold)
      Text('两台测试设备保持此页打开。公钥与密文是公开夹具，不验证真实端到端加密、日历或通知。').fontSize(13)
      Button('A · 生成安全测试码').enabled(!this.busy && this.pairStatus !== 'ACTIVE')
        .onClick(() => this.invoke('createPair', [this.createRequestId, FIXTURE_PUBLIC_KEY, 1]))
      Text('测试码：' + (this.inviteCode || '尚未生成')).fontSize(22).fontWeight(FontWeight.Bold)
      TextInput({ text: this.inviteInput, placeholder: 'B 输入 A 的六位测试码' })
        .type(InputType.Number).maxLength(6).onChange((value: string) => this.inviteInput = value)
      Button('B · 加入安全测试配对').enabled(!this.busy && this.inviteInput.length === 6 && this.pairStatus !== 'ACTIVE')
        .onClick(() => this.invoke('joinPair', [this.inviteInput, FIXTURE_PUBLIC_KEY, 1]))
      Button('A · 确认安全配对').enabled(!this.busy && this.confirmSecret.length > 0 && this.pairId.length > 0)
        .onClick(() => this.invoke('confirmPair', [this.pairId, this.confirmSecret]))
      Button('刷新配对状态').enabled(!this.busy && this.pairId.length > 0)
        .onClick(() => this.invoke('pairStatus', [this.pairId]))
      Text('配对：' + (this.pairStatus || '未配对') + '\n' + this.pairId).fontSize(13)
      Divider()
      TextInput({ text: this.planId, placeholder: '隔离计划 ID' }).enabled(!this.retryPending && !this.busy)
        .onChange((value: string) => { this.planId = value; this.planVersion = 0; this.contentRevision = 0; })
      Button('发送测试邀请').enabled(!this.busy && !this.retryPending && this.pairStatus === 'ACTIVE')
        .onClick(() => this.send('PROPOSE'))
      Button('刷新计划列表').enabled(!this.busy && this.pairStatus === 'ACTIVE')
        .onClick(() => this.invoke('read', [this.pairId]))
      ForEach(this.plans, (row: ProbePlan) => {
        Button(row.planId + ' · ' + row.state + ' · v' + row.stateVersion
          + ' · 已确认修订 ' + row.acceptedRevision).enabled(!this.busy && !this.retryPending)
          .onClick(() => this.choose(row))
      }, (row: ProbePlan) => row.planId + ':' + row.stateVersion)
      Text('当前选中：' + this.planId + ' · v' + this.planVersion).fontSize(13)
      Row({ space: 8 }) {
        Button('同意').onClick(() => this.send('ACCEPT'))
        Button('暂不安排').onClick(() => this.send('DECLINE'))
        Button('撤回').onClick(() => this.send('WITHDRAW'))
      }.enabled(!this.busy && !this.retryPending && this.planVersion > 0 && this.pairStatus === 'ACTIVE')
      Row({ space: 8 }) {
        Button('改期夹具').onClick(() => this.send('AMEND'))
        Button('取消已确认计划').onClick(() => this.send('CANCEL'))
      }.enabled(!this.busy && !this.retryPending && this.planVersion > 0 && this.pairStatus === 'ACTIVE')
      if (this.retryPending) {
        Button('按原 requestId 重试').enabled(!this.busy)
          .onClick(() => this.invoke('mutate', [this.pendingCommand]))
      }
      Text(this.receipt).fontSize(14).width('100%')
      Text('不提供清库或解绑按钮；失败只手动重试。退出此页会丢失测试界面的临时凭据，测试应用不会写正式计划。').fontSize(12)
    }.width('100%').padding(16)
  }
}
