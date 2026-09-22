import abilityTest from './Ability.test';
import upgradeMigrationTest from './UpgradeMigrationTest';

export default function testsuite() {
  abilityTest();
  upgradeMigrationTest();
}
