import { MySchedule, OWNER_ME, OWNER_PARTNER, PersonalEntry, RosterDay, WeeklyScheduleState,
  buildAvailability, emptyWeeklyState, intersects, replaceRosterDays, rosterDayOf,
  rosterError, rosterSnapshot, shiftToBlocks, dayOfStart, ROSTER_LOOKBACK_DAYS } from 'domain';
import { PAIRED, ScheduleRepo, SettingsStore } from 'data';
import { Logger } from 'commons';
import { SerialQueue } from '../model/SerialQueue';
import { ScheduleUseCase, SettingsStoreParams } from './ScheduleUseCase';
import { ScheduleCommandResult } from './ScheduleCommandService';

export interface RosterSaveResult extends ScheduleCommandResult { message: string; warning: boolean; }
const WRITES: SerialQueue = new SerialQueue();

function outcome(message: string, warning: boolean = false, changed: boolean = false,
  recomputed: boolean = false): RosterSaveResult {
  return { ok: message === '', changed: changed, recomputed: recomputed,
    syncQueued: recomputed && SettingsStore.getPairState() === PAIRED,
    errorCode: changed && !recomputed ? 'RECOMPUTE_FAILED' : warning ? 'CONFIRM_OVERLAP' : message !== '' ? 'INVALID_ROSTER' : '',
    message: message, warning: warning };
}
function key(owner: string): string {
  if (owner !== OWNER_ME && owner !== OWNER_PARTNER) throw new Error('日程归属不正确');
  return 'weekly_roster_v1:' + owner;
}
export function personalEntryError(entry: PersonalEntry): string {
  return typeof entry.id !== 'string' || entry.id.length === 0 || typeof entry.title !== 'string'
    || entry.title.trim().length === 0 || entry.title.length > 80 || typeof entry.kind !== 'string'
    || !Number.isInteger(entry.start) || !Number.isInteger(entry.end) || entry.start < 0
    || entry.end <= entry.start || entry.end-entry.start > 1440 ? '请填写标题和有效时间，单次安排不超过24小时' : '';
}
export function decodeWeeklyState(raw: string): WeeklyScheduleState {
  if (raw === '') return emptyWeeklyState();
  const state = JSON.parse(raw) as WeeklyScheduleState;
  if (state == null || state.version !== 1 || typeof state.enabled !== 'boolean'
    || !Array.isArray(state.days) || !Array.isArray(state.personal) || state.days.length > 10000 || state.personal.length > 10000
    || rosterError(state.days) !== '' || state.personal.some((entry: PersonalEntry): boolean => personalEntryError(entry) !== ''))
    throw new Error('已有周班表无法读取，请重试；没有清空数据');
  return state;
}
/** 按 owner 保存整个版本化文档，单次原子写入；串行防止日程与班表相互覆盖。 */
export class WeeklyRosterService {
  static async read(owner: string = OWNER_ME): Promise<WeeklyScheduleState> {
    return decodeWeeklyState(await ScheduleRepo.getMeta(key(owner)));
  }
  static async loadDays(owner: string, start: number, count: number): Promise<RosterDay[]> {
    const params = SettingsStoreParams(); params.horizonDays=count;
    const schedule = await ScheduleUseCase.loadMySchedule(start, params, owner);
    const days: RosterDay[] = [];
    for(let i=0;i<count;i++) days.push(rosterDayOf(schedule,start+i));
    return days;
  }
  static saveDays(owner: string, changes: RosterDay[], acknowledge: boolean = false): Promise<RosterSaveResult> {
    const detached = changes.map(rosterSnapshot);
    return WRITES.run(async (): Promise<RosterSaveResult> => {
      try {
        const invalid = rosterError(detached); if (invalid !== '') return outcome(invalid);
        if (detached.length===0) return outcome('');
        const state = await WeeklyRosterService.read(owner);
        const ordered=detached.slice().sort((a: RosterDay,b: RosterDay): number => a.epochDay-b.epochDay);
        const first = Math.max(0,ordered[0].epochDay-ROSTER_LOOKBACK_DAYS);
        const last = ordered[ordered.length-1].epochDay+ROSTER_LOOKBACK_DAYS;
        if (last-first > 370) return outcome('一次最多安排一年，请缩短重复范围');
        const params = SettingsStoreParams(); params.horizonDays=last-first+1;
        const schedule = await ScheduleUseCase.loadMySchedule(first,params,owner);
        schedule.datedDays=replaceRosterDays(state.days,detached); schedule.weeklyMode=true;
        const effective: RosterDay[] = [];
        for(let d=first;d<=last;d++) effective.push(rosterDayOf(schedule,d));
        const conflict = rosterError(effective); if(conflict !== '') return outcome(conflict);
        if (!acknowledge && WeeklyRosterService.hasSoftOverlap(schedule,effective,detached,first))
          return outcome('与课程、个人安排、共同计划，或通勤／恢复时段有重叠。已有安排不会被改动；仍要保存请再次确认。',true);
        state.enabled=true; state.days=replaceRosterDays(state.days,detached);
        await ScheduleRepo.setMeta(key(owner),JSON.stringify(state));
        return await WeeklyRosterService.afterWrite();
      } catch(e) { Logger.warn('WeeklyRoster','save failed: '+(e as Error).message); return outcome('保存未完成，请重试；原有数据保留'); }
    });
  }
  private static hasSoftOverlap(schedule: MySchedule, effective: RosterDay[], changes: RosterDay[], first: number): boolean {
    const params=SettingsStoreParams(); params.horizonDays=effective.length;
    const busy=buildAvailability(schedule,params,first,effective.length).trueBusy;
    for(const day of changes) {
      for(const own of day.entries) {
        const ownBlocks=shiftToBlocks({epochDay:day.epochDay,typeId:own.id},own,params);
        if(ownBlocks.some(iv => busy.some(b => ['COURSE','PERSONAL','PLAN'].indexOf(b.tag)>=0
          && intersects(iv.start,iv.end,b.start,b.end)))) return true;
        for(const otherDay of effective) for(const other of otherDay.entries) {
          if(otherDay.epochDay===day.epochDay && other.id===own.id) continue;
          const blocks=shiftToBlocks({epochDay:otherDay.epochDay,typeId:other.id},other,params);
          if(ownBlocks.some(iv => blocks.some(b => intersects(iv.start,iv.end,b.start,b.end)))) return true;
        }
      }
    }
    return false;
  }
  static savePersonal(owner: string, entry: PersonalEntry, acknowledge: boolean = false): Promise<RosterSaveResult> {
    const detached = JSON.parse(JSON.stringify(entry)) as PersonalEntry;
    return WRITES.run(async (): Promise<RosterSaveResult> => {
      try {
        const invalid=personalEntryError(detached); if(invalid!=='')return outcome(invalid);
        const state=await WeeklyRosterService.read(owner);
        const day=dayOfStart(detached.start);
        const params=SettingsStoreParams();params.horizonDays=4;
        const schedule=await ScheduleUseCase.loadMySchedule(day-1,params,owner);
        schedule.personalEntries=(schedule.personalEntries || []).filter((p: PersonalEntry): boolean => p.id!==detached.id);
        const busy=buildAvailability(schedule,params,day-1,4).trueBusy;
        if(!acknowledge && busy.some(iv => iv.tag!=='UNKNOWN' && intersects(iv.start,iv.end,detached.start,detached.end)))
          return outcome('这段时间已有安排。仍要保存请再次确认，不会替换原有内容。',true);
        state.personal=state.personal.filter((p: PersonalEntry): boolean => p.id!==detached.id).concat([detached]);
        await ScheduleRepo.setMeta(key(owner),JSON.stringify(state));
        return await WeeklyRosterService.afterWrite();
      } catch(e) {Logger.warn('WeeklyRoster','personal save failed: '+(e as Error).message);return outcome('个人日程未保存，请重试');}
    });
  }
  static removePersonal(owner: string,id: string): Promise<RosterSaveResult> {
    return WRITES.run(async (): Promise<RosterSaveResult> => {
      try {const state=await WeeklyRosterService.read(owner);state.personal=state.personal.filter((p: PersonalEntry): boolean=>p.id!==id);
        await ScheduleRepo.setMeta(key(owner),JSON.stringify(state));return await WeeklyRosterService.afterWrite();}
      catch(e){return outcome('日程未删除，请重试');}
    });
  }
  private static async afterWrite(): Promise<RosterSaveResult> {
    try {await ScheduleUseCase.onScheduleChanged(true);return outcome('',false,true,true);}
    catch(e){Logger.warn('WeeklyRoster','recompute failed after save');return outcome('已保存，共同时间暂未刷新',false,true,false);}
  }
}
