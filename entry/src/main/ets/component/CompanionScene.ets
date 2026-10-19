import { BUBU_RIG_X, BUBU_RIG_Y, BUBU_RIG_SCALE, XIUXIU_RIG_X, XIUXIU_RIG_Y, XIUXIU_RIG_SCALE } from '../util/CompanionRig';
import { CompanionActor } from './CompanionActor';

@Component
export struct CompanionScene {
  @Prop bearClosed: boolean = false;
  @Prop bunnyClosed: boolean = false;
  @Prop sceneWidth: number = 112;
  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Stack({ alignContent: Alignment.TopStart }) {
        Stack() { CompanionActor({ isBear: true, closed: this.bearClosed }) }
          .width(120).height(120).scale({ x: BUBU_RIG_SCALE, y: BUBU_RIG_SCALE, centerX: 0, centerY: 0 })
          .position({ x: BUBU_RIG_X, y: BUBU_RIG_Y })
        Stack() { CompanionActor({ isBear: false, closed: this.bunnyClosed }) }
          .width(120).height(120).scale({ x: XIUXIU_RIG_SCALE, y: XIUXIU_RIG_SCALE, centerX: 0, centerY: 0 })
          .position({ x: XIUXIU_RIG_X, y: XIUXIU_RIG_Y })
      }.width(112).height(44)
        .scale({ x: this.sceneWidth / 112, y: this.sceneWidth / 112, centerX: 0, centerY: 0 })
        .position({ x: 0, y: 44 * (1 - this.sceneWidth / 112) })
    }.width(this.sceneWidth).height(44).clip(true).hitTestBehavior(HitTestMode.None).accessibilityLevel('no')
  }
}
