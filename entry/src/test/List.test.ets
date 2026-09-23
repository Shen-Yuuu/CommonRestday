import localUnitTest from './LocalUnit.test';
import presentationModelsTest from './PresentationModelsTest';
import commonTimeQueryServiceTest from './CommonTimeQueryServiceTest';
import rhythmRulesTest from './RhythmRulesTest';
import dbMigrationTest from './DbMigrationTest';
import scheduleCommandServiceTest from './ScheduleCommandServiceTest';
import planUseCaseTest from './PlanUseCaseTest';
import cardSummaryServiceTest from './CardSummaryServiceTest';
import planKindsTest from './PlanKindsTest';
import profileSettingsGuardTest from './ProfileSettingsGuardTest';

export default function testsuite() {
  localUnitTest();
  presentationModelsTest();
  commonTimeQueryServiceTest();
  rhythmRulesTest();
  dbMigrationTest();
  scheduleCommandServiceTest();
  planUseCaseTest();
  cardSummaryServiceTest();
  planKindsTest();
  profileSettingsGuardTest();
}
