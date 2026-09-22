import localUnitTest from './LocalUnit.test';
import presentationModelsTest from './PresentationModelsTest';
import dbMigrationTest from './DbMigrationTest';

export default function testsuite() {
  localUnitTest();
  presentationModelsTest();
  dbMigrationTest();
}
