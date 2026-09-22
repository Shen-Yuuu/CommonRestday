import localUnitTest from './LocalUnit.test';
import presentationModelsTest from './PresentationModelsTest';

export default function testsuite() {
  localUnitTest();
  presentationModelsTest();
}
