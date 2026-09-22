import { ContainerReader, ContainerReaderAttribute, Size } from '@kit.ArkUI';
import { Breakpoint, Breakpoints } from './Breakpoints';

/**
 * 容器级响应式的量宽外壳：只负责"这块内容有多宽"，不参与排版。
 *
 * - 主口径是 API 26 的 ContainerReader：它按自身布局尺寸回灌 size（vp），
 *   子节点撑不它、也不受它的内容影响，所以能把整页塞进去当被测容器；
 * - 副口径是 onAreaChange（API 8 起就有）：ContainerReader 的 `!!` 回灌在本轮
 *   无设备可验，两路都写进同一个幂等入口，任一路先到都能出断点；
 * - 量不到（宽度 ≤0）时什么都不做，父页面停留在上一档 —— 首帧之前的默认值就是
 *   COMPACT，也就是改造前的布局，最坏情况等于没有这层。
 */
@Component
export struct ResponsiveContainer {
  /** 断点出口：写回父页面，由父页面决定单栏/双栏与留白。 */
  @Link breakpoint: Breakpoint;
  /** ContainerReader 的输出参数（不是输入：不能靠它改容器尺寸）。命名避开 CustomComponent.size。 */
  @State @Watch('onSizeChanged') private containerSize: Size = { width: 0, height: 0 };
  @BuilderParam content: () => void = this.placeholder;

  @Builder
  placeholder(): void {
  }

  onSizeChanged(): void {
    this.applyWidth(this.containerSize.width);
  }

  /** 幂等写断点：同宽不写状态，避免"写入→重排→再写入"的布局回环。 */
  private applyWidth(vp: number): void {
    if (vp <= 0) {
      return;
    }
    const next: Breakpoint = Breakpoints.ofWidth(vp);
    if (next !== this.breakpoint) {
      this.breakpoint = next;
    }
  }

  build() {
    // ContainerReaderAttribute 必须和 ContainerReader 一起 import，否则内置组件属性解析不到；
    // 这里不调 breakpointConfig，阈值判定留在 Breakpoints.ofWidth 里（口径只有一处）。
    ContainerReader({ size: this.containerSize!! }) {
      this.content()
    }
    .width('100%')
    .height('100%')
    .onAreaChange((_oldValue: Area, newValue: Area) => {
      this.applyWidth(Breakpoints.widthOf(newValue));
    })
  }
}
