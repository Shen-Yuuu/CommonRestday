import { AnonymousIdentity, DatePlanCloudApi, SecurePlanKeyStore } from 'cloud';
import { SecureCleanupRow, SecurePairingRepo } from 'data';
import { FeatureFlags } from '../config/FeatureFlags';
import { PlanCloudPort, PlanIdentity, PlanIdentityPort } from './SecureSharedPlanGateway';
import { SecureCleanupRecord, SecureCleanupStore, SecureCleanupUseCase } from './SecureCleanupUseCase';
import { SecureLifecycle } from './SecureLifecycle';

class CleanupIdentity implements PlanIdentityPort {
  credential(create: boolean): Promise<PlanIdentity> { return AnonymousIdentity.credential(false); }
}
class CleanupCloud implements PlanCloudPort {
  invoke(method: string, token: string, params: Object[]): Promise<string> {
    return DatePlanCloudApi.invoke(method, token, params);
  }
}
function dataRow(row: SecureCleanupRecord): SecureCleanupRow {
  return { flowId: row.flowId, authUid: row.authUid, pairId: row.pairId, status: row.status };
}
class CleanupStore implements SecureCleanupStore {
  async list(): Promise<SecureCleanupRecord[]> {
    return (await SecurePairingRepo.cleanupRecords()).map((row: SecureCleanupRow): SecureCleanupRecord => {
      const mapped: SecureCleanupRecord = { flowId: row.flowId, authUid: row.authUid, pairId: row.pairId, status: row.status };
      return mapped;
    });
  }
  async current(row: SecureCleanupRecord): Promise<boolean> {
    return (await this.list()).some(item => item.flowId === row.flowId && item.authUid === row.authUid
      && item.pairId === row.pairId && item.status === row.status);
  }
  finish(row: SecureCleanupRecord, status: string): Promise<void> { return SecurePairingRepo.finishCleanup(dataRow(row), status); }
  async drop(row: SecureCleanupRecord): Promise<void> {
    if (row.authUid !== '') await SecurePlanKeyStore.dropProof(row.authUid, row.flowId);
    if (row.pairId !== '') await SecurePlanKeyStore.drop(row.pairId);
  }
}
let instance: SecureCleanupUseCase | null = null;
export function secureCloudCleanup(): SecureCleanupUseCase {
  if (instance === null) instance = new SecureCleanupUseCase(new CleanupIdentity(), new CleanupCloud(), new CleanupStore(),
    () => FeatureFlags.cloudPairing && !SecureLifecycle.blocked());
  return instance;
}
/** Local metadata only, including when new capability gates are closed. */
export async function secureCleanupSummary(): Promise<string> {
  const rows = await SecurePairingRepo.cleanupRecords();
  if (rows.length === 0) return '';
  const cloud = rows.filter(row => row.status !== 'LOCAL_KEYS');
  const local = rows.length - cloud.length;
  const review = cloud.filter(row => row.status !== 'WAITING' && row.status !== 'UNRESOLVED_CREATE').length;
  return (cloud.length > 0 ? '共同计划连接有 ' + cloud.length + ' 项云端清理待完成或核实。'
    + (review > 0 ? '其中 ' + review + ' 份需核实原身份或连接，重试不会自动恢复它们。' : '重试需要这台设备原有的云身份。') : '')
    + (local > 0 ? '另有 ' + local + ' 项本机密钥清理待完成；云端连接已撤销。' : '');
}
