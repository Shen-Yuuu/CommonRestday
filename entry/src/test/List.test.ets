import localUnitTest from './LocalUnit.test';
import presentationModelsTest from './PresentationModelsTest';
import commonTimeQueryServiceTest from './CommonTimeQueryServiceTest';
import dbMigrationTest from './DbMigrationTest';

export default function testsuite() {
  localUnitTest();
  presentationModelsTest();
  commonTimeQueryServiceTest();
  dbMigrationTest();
}
