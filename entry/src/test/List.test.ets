import localUnitTest from './LocalUnit.test';
import presentationModelsTest from './PresentationModelsTest';
import commonTimeQueryServiceTest from './CommonTimeQueryServiceTest';
import rhythmRulesTest from './RhythmRulesTest';
import dbMigrationTest from './DbMigrationTest';

export default function testsuite() {
  localUnitTest();
  presentationModelsTest();
  commonTimeQueryServiceTest();
  rhythmRulesTest();
  dbMigrationTest();
}
