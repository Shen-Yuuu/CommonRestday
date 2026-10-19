import { describe, it, expect } from '@ohos/hypium';
import { MySchedule, ShiftType, RosterDay, defaultParams, MIN_PER_DAY } from '../main/ets/model/Types';
import { copyRosterWeek, rosterDayOf, rosterError, rosterSnapshot, shiftError, weekMonday } from '../main/ets/expand/WeeklyRoster';
import { buildAvailability, CommonFreeEngine } from '../main/ets/engine/CommonFreeEngine';
import { SnapshotBuilder } from '../main/ets/snapshot/SnapshotBuilder';
import { SnapshotCodec } from '../main/ets/snapshot/SnapshotCodec';
import { intersects } from '../main/ets/merge/IntervalOps';

function shift(id: string, start: number, end: number): ShiftType {
  return { id: id, name: id, color: '#9A6BDC', startMin: start, endMin: end, crossDay: end<=start,
    commuteInMin: 0, commuteOutMin: 0, recoveryMin: 0, nightMode: 2, allowActivity: false, kind: 'WORK' };
}
function day(date: number, entries: ShiftType[]): RosterDay {
  return { epochDay: date, status: entries.length>0?'WORK':'REST', entries: entries };
}
function schedule(days: RosterDay[]): MySchedule {
  return { shiftTypes: [], template: null, overrides: [], courses: [], sectionTimes: [], termStartEpochDay: -1,
    plans: [], wakeMin: 0, bedMin: 1440, windDownMin: 0, datedDays: days, weeklyMode: true, personalEntries: [] };
}
export default function weeklyRosterTest() {
  describe('weeklyRoster', () => {
    it('week_starts_on_monday', 0, () => {
      expect(weekMonday(4)).assertEqual(4);
      expect(weekMonday(10)).assertEqual(4);
    });
    it('two_separate_shifts_are_valid', 0, () => {
      expect(rosterError([day(20000,[shift('AM',540,720),shift('PM',840,1080)])])).assertEqual('');
    });
    it('touching_shifts_are_valid_but_overlap_is_not', 0, () => {
      expect(rosterError([day(20000,[shift('A',540,720),shift('B',720,840)])])).assertEqual('');
      expect(rosterError([day(20000,[shift('A',540,720),shift('B',719,840)])])!=='').assertTrue();
    });
    it('overnight_checks_the_next_date_and_week_boundary', 0, () => {
      expect(rosterError([day(20000,[shift('night',1320,420)]),day(20001,[shift('early',360,720)])])!=='').assertTrue();
      expect(rosterError([day(20000,[shift('night',1320,420)]),day(20001,[shift('early',420,720)])])).assertEqual('');
    });
    it('split_shift_preserves_its_lunch_gap', 0, () => {
      const st=shift('split',540,1080);
      st.segments=[{startMin:540,endMin:720,crossDay:false},{startMin:840,endMin:1080,crossDay:false}];
      expect(shiftError(st)).assertEqual('');
      const base=20000*MIN_PER_DAY;
      const avail=buildAvailability(schedule([day(20000,[st])]),defaultParams(),20000,1);
      expect(avail.trueBusy.length).assertEqual(2);
      expect(avail.notAvailable.some(iv=>intersects(iv.start,iv.end,base+720,base+840))).assertFalse();
      st.segments[1].startMin=700;
      expect(shiftError(st)!=='').assertTrue();
    });
    it('next_day_more_than_24_hours_is_rejected', 0, () => {
      const st=shift('bad',540,600);st.crossDay=true;
      expect(shiftError(st)!=='').assertTrue();
    });
    it('snapshot_detaches_preset_and_segments', 0, () => {
      const st=shift('original',540,720);st.segments=[{startMin:540,endMin:720,crossDay:false}];
      const frozen=rosterSnapshot(day(20000,[st]));
      st.name='changed';st.segments[0].startMin=600;
      expect(frozen.entries[0].name).assertEqual('original');
      expect(frozen.entries[0].segments![0].startMin).assertEqual(540);
    });
    it('dated_day_wins_and_other_dates_keep_legacy', 0, () => {
      const s=schedule([day(20000,[])]);
      s.shiftTypes=[shift('legacy',540,1080)];
      s.template={id:'t',name:'old',seq:['legacy'],anchorEpochDay:20000};
      expect(rosterDayOf(s,20000).status).assertEqual('REST');
      expect(rosterDayOf(s,20001).entries[0].name).assertEqual('legacy');
      expect(buildAvailability(s,defaultParams(),20000,1).trueBusy.some(iv=>iv.start>=20000*1440)).assertFalse();
    });
    it('overnight_carries_into_current_compute_range', 0, () => {
      const s=schedule([day(19999,[shift('night',1320,420)]),day(20000,[])]);
      const base=20000*1440;
      expect(buildAvailability(s,defaultParams(),20000,1).trueBusy.some(iv=>intersects(iv.start,iv.end,base,base+420))).assertTrue();
    });
    it('following_day_commute_and_prior_recovery_cross_the_range', 0, () => {
      const next=shift('next',30,60);next.commuteInMin=60;
      const base=20000*1440;
      const s=schedule([day(20000,[]),day(20001,[next])]);
      expect(buildAvailability(s,defaultParams(),20000,1).trueBusy.some(iv=>intersects(iv.start,iv.end,base+1410,base+1440))).assertTrue();
      const old=shift('old',1380,1380);old.commuteOutMin=1440;old.recoveryMin=1440;old.nightMode=1;
      const carried=schedule([day(19997,[old]),day(20000,[])]);
      expect(buildAvailability(carried,defaultParams(),20000,1).trueBusy.some(iv=>iv.tag==='RECOVERY'&&intersects(iv.start,iv.end,base,base+1380))).assertTrue();
    });
    it('unassigned_does_not_occupy_time_in_work_mode', 0, () => {
      const s=schedule([]),p=defaultParams();p.horizonDays=1;
      expect(CommonFreeEngine.compute({my:s,partner:null,params:p,horizonStartEpochDay:20000}).windows.length>0).assertTrue();
      expect(buildAvailability(s,p,20000,1).trueBusy.length).assertEqual(0);
      s.weeklyMode=false;
      expect(buildAvailability(s,p,20000,1).trueBusy.length).assertEqual(0);
    });
    it('unassigned_still_respects_waking_hours', 0, () => {
      const s=schedule([]),p=defaultParams();p.horizonDays=1;s.wakeMin=420;s.bedMin=1320;
      const base=20000*MIN_PER_DAY;
      const result=CommonFreeEngine.compute({my:s,partner:null,params:p,horizonStartEpochDay:20000});
      expect(result.windows.some(w=>w.start===base+420&&w.end===base+1320)).assertTrue();
      expect(buildAvailability(s,p,20000,1).notAvailable.some(iv=>intersects(iv.start,iv.end,base,base+420))).assertTrue();
    });
    it('explicit_unknown_day_keeps_personal_and_confirmed_plan_busy', 0, () => {
      const s=schedule([{epochDay:20000,status:'UNKNOWN',entries:[]}]),base=20000*MIN_PER_DAY;
      s.personalEntries=[{id:'p',title:'private',kind:'other',start:base+600,end:base+660}];
      s.plans=[{start:base+720,end:base+780}];
      const busy=buildAvailability(s,defaultParams(),20000,1).trueBusy;
      expect(busy.some(iv=>iv.tag==='PERSONAL')).assertTrue();
      expect(busy.some(iv=>iv.tag==='PLAN')).assertTrue();
      expect(busy.some(iv=>iv.tag==='UNKNOWN')).assertFalse();
    });
    it('unknown_day_has_no_recovery_buffer_into_known_rest', 0, () => {
      const s=schedule([day(20001,[])]);s.windDownMin=90;
      const base=20001*1440;
      expect(buildAvailability(s,defaultParams(),20000,2).notAvailable.some(iv=>intersects(iv.start,iv.end,base,base+90))).assertFalse();
    });
    it('personal_entry_is_not_a_joint_plan', 0, () => {
      const s=schedule([day(20000,[])]);const base=20000*1440;
      s.personalEntries=[{id:'p',title:'gym',kind:'运动',start:base+600,end:base+660}];
      expect(buildAvailability(s,defaultParams(),20000,1).trueBusy[0].tag).assertEqual('PERSONAL');
      expect(s.plans.length).assertEqual(0);
    });
    it('rest_and_unknown_are_not_interchangeable', 0, () => {
      expect(rosterError([{epochDay:20000,status:'REST',entries:[shift('x',1,2)]}])!=='').assertTrue();
      expect(rosterDayOf(schedule([]),20000).status).assertEqual('UNKNOWN');
      expect(rosterDayOf(schedule([day(20000,[])]),20000).status).assertEqual('REST');
    });
    it('all_snapshot_levels_conserve_new_occupancy', 0, () => {
      const s=schedule([day(20000,[])]),p=defaultParams();p.horizonDays=2;
      s.personalEntries=[{id:'p',title:'private title',kind:'就医',start:20000*1440+600,end:20000*1440+660}];
      for(const level of [1,2,3]){
        const wire=SnapshotCodec.encode(SnapshotBuilder.build(s,p,20000,level,1));
        expect(wire.indexOf('private title')).assertEqual(-1);
        const decoded=SnapshotCodec.decode(wire)!;
        const busy=SnapshotCodec.toIntervals(decoded);
        expect(busy.some(iv=>intersects(iv.start,iv.end,20000*1440+600,20000*1440+660))).assertTrue();
        expect(busy.some(iv=>intersects(iv.start,iv.end,20001*1440,20002*1440))).assertFalse();
      }
    });
    it('copy_strategies_preserve_replace_or_merge', 0, () => {
      const monday=weekMonday(20000),source: RosterDay[]=[];
      for(let i=0;i<7;i++)source.push(day(monday+i,i===0?[shift('AM',540,720)]:[]));
      const existing=[day(monday+7,[shift('PM',840,1080)])];
      expect(copyRosterWeek(source,existing,[monday+7],'KEEP').length).assertEqual(6);
      const replaced=copyRosterWeek(source,existing,[monday+7],'REPLACE');
      expect(replaced[0].entries.length).assertEqual(1);
      const merged=copyRosterWeek(source,existing,[monday+7],'MERGE');
      expect(merged[0].entries.length).assertEqual(2);
      expect(rosterError(merged)).assertEqual('');
      expect(source[0].entries[0].id).assertEqual('AM');
    });
    it('copy_skips_unknown_source_without_erasing_target', 0, () => {
      const monday=weekMonday(20000),source: RosterDay[]=[];
      for(let i=0;i<7;i++)source.push({epochDay:monday+i,status:'UNKNOWN',entries:[]});
      expect(copyRosterWeek(source,[day(monday+7,[shift('old',1,2)])],[monday+7],'REPLACE').length).assertEqual(0);
    });
    it('merge_overlap_is_rejected_before_persistence', 0, () => {
      const monday=weekMonday(20000),source: RosterDay[]=[];
      for(let i=0;i<7;i++)source.push(day(monday+i,[shift('AM',540,720)]));
      expect(rosterError(copyRosterWeek(source,[day(monday+7,[shift('old',600,840)])],[monday+7],'MERGE'))!=='').assertTrue();
    });
  });
}
