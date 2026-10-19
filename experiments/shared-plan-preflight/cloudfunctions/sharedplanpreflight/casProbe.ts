import { CloudDBCollection } from '@hw-agconnect/cloud-server';
import { randomUUID } from 'crypto';
import { PlanCasProbe } from './PlanCasProbe';

export interface CasLeg {
  state: string;
  outcome: 'APPLIED' | 'NOT_COMMITTED' | 'SDK_ERROR';
  readVersions: number[];
}

export interface CasProbeResult {
  code: string;
  probeId: string;
  legs: CasLeg[];
  finalVersion: number;
  finalState: string;
  overlapObserved: boolean;
  sharedPlanReady: false;
  message: string;
}

function rowOf(id: string, version: number, state: string, createdAt: number): PlanCasProbe {
  const row = new PlanCasProbe();
  row.setId(id); row.setVersion(version); row.setState(state); row.setCreatedAt(createdAt);
  return row;
}

/** Two independent SDK transactions, overlapping their reads before committing.
 * The in-memory barrier is ONLY a probe instrument; it is NOT a production write lock or CAS. */
export async function probeTransactionRace(collection: CloudDBCollection<PlanCasProbe>): Promise<CasProbeResult> {
  const id = 'cas-' + randomUUID();
  const result: CasProbeResult = { code: 'RACE_INCONCLUSIVE', probeId: id, legs: [], finalVersion: 0,
    finalState: '', overlapObserved: false, sharedPlanReady: false, message: '事务探针未完成' };
  const seed = rowOf(id, 1, 'PENDING', Date.now());
  try {
    if (await collection.insert(seed) !== 1) return result;
  } catch {
    result.code = 'DB_UNAVAILABLE';
    result.message = '隔离测试表未就绪或数据库调用失败';
    return result;
  }

  let arrived = 0;
  let expired = false;
  let release: () => void = () => {};
  const overlap = new Promise<void>(resolve => { release = resolve; });
  const timer = setTimeout(() => { expired = true; release(); }, 3000);
  async function compete(state: string): Promise<CasLeg> {
    const leg: CasLeg = { state, outcome: 'NOT_COMMITTED', readVersions: [] };
    try {
      const committed = await collection.runTransaction({
        async apply(transaction) {
          const rows = await transaction.executeQuery(collection.query().equalTo('id', id));
          if (rows.length !== 1) return false;
          leg.readVersions.push(rows[0].getVersion());
          if (rows[0].getVersion() !== 1 || rows[0].getState() !== 'PENDING') return false;
          arrived++;
          if (arrived >= 2) { clearTimeout(timer); release(); }
          await overlap;
          if (expired) return false;
          transaction.executeUpsert([rowOf(id, 2, state, rows[0].getCreatedAt())]);
          return true;
        }
      });
      leg.outcome = committed ? 'APPLIED' : 'NOT_COMMITTED';
    } catch {
      // A generic SDK/network exception is not proof that the losing request was rejected by CAS.
      leg.outcome = 'SDK_ERROR';
    }
    return leg;
  }

  try {
    result.legs = await Promise.all([compete('ACCEPTED'), compete('WITHDRAWN')]);
    result.overlapObserved = !expired && result.legs.every(leg => leg.readVersions[0] === 1);
    const rows = await collection.query().equalTo('id', id).get();
    if (rows.length === 1) {
      result.finalVersion = rows[0].getVersion();
      result.finalState = rows[0].getState();
    }
    const winners = result.legs.filter(leg => leg.outcome === 'APPLIED');
    const losers = result.legs.filter(leg => leg.outcome === 'NOT_COMMITTED');
    if (result.overlapObserved && winners.length === 1 && losers.length === 1
      && result.finalVersion === 2 && result.finalState === winners[0].state) {
      result.code = 'OK';
      result.message = '事务竞争通过；仅验证独立测试表';
    } else if (winners.length === 2) {
      result.code = 'RACE_FAILED';
      result.message = '两个竞争请求都提交了；不得开放共同计划写入';
    } else {
      result.message = '尚未证实重叠读取后仅一个提交；请保留回包核对';
    }
  } catch {
    result.message = '读取事务终态失败；不能判通过';
  } finally {
    clearTimeout(timer);
    release();
  }
  // Leave this single isolated diagnostic row for the operator to compare with the returned receipt.
  return result;
}
