import timeUtilTest from './TimeUtilTest.ets';
import cycleExpanderTest from './CycleExpanderTest.ets';
import courseExpanderTest from './CourseExpanderTest.ets';
import courseTextParserTest from './CourseTextParserTest.ets';
import intervalOpsTest from './IntervalOpsTest.ets';
import availabilityBuilderTest from './AvailabilityBuilderTest.ets';
import classifierTest from './ClassifierTest.ets';
import conflictTest from './ConflictTest.ets';
import engineTest from './EngineTest.ets';
import snapshotTest from './SnapshotTest.ets';

export default function testsuite() {
  timeUtilTest();
  cycleExpanderTest();
  courseExpanderTest();
  courseTextParserTest();
  intervalOpsTest();
  availabilityBuilderTest();
  classifierTest();
  conflictTest();
  engineTest();
  snapshotTest();
}
