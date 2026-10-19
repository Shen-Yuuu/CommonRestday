import { describe, it, expect } from '@ohos/hypium';
import { ScheduleRepo } from 'data';
import { RosterDay, PersonalEntry, ShiftType, emptyWeeklyState } from 'domain';
import { WeeklyRosterService, decodeWeeklyState } from 'feature';

const DATE=20000;
function shift(id: string,start: number,end: number): ShiftType {
  return {id:id,name:id,color:'#9A6BDC',startMin:start,endMin:end,crossDay:end<=start,
    commuteInMin:0,commuteOutMin:0,recoveryMin:0,nightMode:2,allowActivity:false,kind:'WORK'};
}
function work(id: string,start: number,end: number): RosterDay {
  return {epochDay:DATE,status:'WORK',entries:[shift(id,start,end)]};
}
function personal(id: string,start: number,end: number): PersonalEntry {
  return {id:id,title:'个人安排',kind:'运动',start:DATE*1440+start,end:DATE*1440+end};
}
async function reset(): Promise<void> {
  await ScheduleRepo.setMeta('weekly_roster_v1:ME',JSON.stringify(emptyWeeklyState()));
  await ScheduleRepo.setMeta('weekly_roster_v1:PARTNER',JSON.stringify(emptyWeeklyState()));
}
export default function weeklyRosterServiceTest() {
  describe('weeklyRosterService', () => {

    it('owner_isolation_and_successful_readback', 0, async () => {
      await reset();
      const r=await WeeklyRosterService.saveDays('ME',[work('A',540,720)]);
      expect(r.changed).assertTrue();expect(r.recomputed).assertTrue();
      expect((await WeeklyRosterService.read('ME')).days[0].entries[0].name).assertEqual('A');
      expect((await WeeklyRosterService.read('PARTNER')).days.length).assertEqual(0);
    });
    it('conflict_leaves_entire_stored_document_unchanged', 0, async () => {
      await reset();
      await WeeklyRosterService.saveDays('ME',[work('A',540,720)]);
      const old=await ScheduleRepo.getMeta('weekly_roster_v1:ME');
      const bad=work('A',540,720);bad.entries.push(shift('B',600,840));
      expect((await WeeklyRosterService.saveDays('ME',[bad])).changed).assertFalse();
      expect(await ScheduleRepo.getMeta('weekly_roster_v1:ME')).assertEqual(old);
    });
    it('neighbor_overnight_conflict_is_found', 0, async () => {
      await reset();
      const night=work('night',1320,420);night.epochDay=DATE-1;
      await WeeklyRosterService.saveDays('ME',[night]);
      expect((await WeeklyRosterService.saveDays('ME',[work('early',360,720)])).changed).assertFalse();
      expect((await WeeklyRosterService.saveDays('ME',[work('early',420,720)])).changed).assertTrue();
    });
    it('overlap_needs_confirmation_without_erasing_personal', 0, async () => {
      await reset();
      await WeeklyRosterService.savePersonal('ME',personal('p',600,660));
      const first=await WeeklyRosterService.saveDays('ME',[work('A',540,720)]);
      expect(first.warning).assertTrue();expect(first.changed).assertFalse();
      expect((await WeeklyRosterService.saveDays('ME',[work('A',540,720)],true)).changed).assertTrue();
      expect((await WeeklyRosterService.read('ME')).personal.length).assertEqual(1);
    });
    it('commute_overlap_requires_confirmation', 0, async () => {
      await reset();
      await WeeklyRosterService.savePersonal('ME',personal('p',500,530));
      const d=work('A',540,720);d.entries[0].commuteInMin=45;
      expect((await WeeklyRosterService.saveDays('ME',[d])).warning).assertTrue();
    });
    it('editing_personal_does_not_conflict_with_itself', 0, async () => {
      await reset();
      await WeeklyRosterService.savePersonal('ME',personal('p',600,660));
      const r=await WeeklyRosterService.savePersonal('ME',personal('p',615,675));
      expect(r.changed).assertTrue();expect(r.warning).assertFalse();
      const state=await WeeklyRosterService.read('ME');
      expect(state.personal.length).assertEqual(1);expect(state.enabled).assertFalse();
    });
    it('parallel_personal_and_roster_save_preserve_both', 0, async () => {
      await reset();
      const results=await Promise.all([
        WeeklyRosterService.saveDays('ME',[work('A',540,720)]),
        WeeklyRosterService.savePersonal('ME',personal('p',840,900))
      ]);
      expect(results[0].changed).assertTrue();expect(results[1].changed).assertTrue();
      const state=await WeeklyRosterService.read('ME');
      expect(state.days.length).assertEqual(1);expect(state.personal.length).assertEqual(1);
    });
    it('corrupt_storage_is_not_treated_as_empty_or_overwritten', 0, async () => {
      await reset();
      await ScheduleRepo.setMeta('weekly_roster_v1:ME','broken');
      let rejected=false;try{await WeeklyRosterService.read('ME');}catch(e){rejected=true;}
      expect(rejected).assertTrue();
      expect((await WeeklyRosterService.saveDays('ME',[work('A',540,720)])).changed).assertFalse();
      expect(await ScheduleRepo.getMeta('weekly_roster_v1:ME')).assertEqual('broken');
    });
    it('unsupported_version_is_rejected', 0, () => {
      let rejected=false;
      try{decodeWeeklyState('{"version":2,"enabled":false,"days":[],"personal":[]}');}catch(e){rejected=true;}
      expect(rejected).assertTrue();
    });
    it('removing_personal_keeps_work_and_owner_independence', 0, async () => {
      await reset();
      await WeeklyRosterService.saveDays('ME',[work('A',540,720)]);
      await WeeklyRosterService.savePersonal('ME',personal('p',840,900));
      await WeeklyRosterService.savePersonal('PARTNER',personal('p',840,900));
      expect((await WeeklyRosterService.removePersonal('ME','p')).changed).assertTrue();
      expect((await WeeklyRosterService.read('ME')).days.length).assertEqual(1);
      expect((await WeeklyRosterService.read('ME')).personal.length).assertEqual(0);
      expect((await WeeklyRosterService.read('PARTNER')).personal.length).assertEqual(1);
    });
  });
}
