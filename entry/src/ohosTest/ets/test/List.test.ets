import abilityTest from './Ability.test';
import upgradeMigrationTest from './UpgradeMigrationTest';
import partnerNamePersistenceTest from './PartnerNamePersistenceTest';

export default function testsuite() {
  abilityTest();
  upgradeMigrationTest();
  partnerNamePersistenceTest();
}
