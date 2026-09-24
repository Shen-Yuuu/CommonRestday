import { uiMaterial } from '@kit.ArkUI';
import { Logger } from 'commons';

const TAG = 'MaterialPolicy';

/** 玻璃表面的两条渲染路径：系统沉浸材质 / 近实色回退。 */
export enum GlassMode {
  SYSTEM = 'SYSTEM',
  SOLID = 'SOLID'
}

/**
 * 玻璃强度。STRONG 给悬浮底栏与 Sheet（需要稳住其下的滚动内容），
 * SOFT 给首页唯一主结果（透一点，但仍要保证深莓底上的暖白字对比）。
 */
export enum GlassStrength {
  STRONG = 'STRONG',
  SOFT = 'SOFT'
}

/**
 * 材质能力探测：设备是否支持沉浸材质、应用级材质是否被关掉、算力档位够不够。
 * 结论与材质对象都在这里，页面与容器只问「走哪条路」，不自行读系统能力。
 */
export class MaterialPolicy {
  private static probed: GlassMode | null = null;
  private static strongMaterial: uiMaterial.ImmersiveMaterial | null = null;
  private static softMaterial: uiMaterial.ImmersiveMaterial | null = null;

  /**
   * 三条都成立才允许材质路径：设备支持、应用未禁用材质、非低算力档。
   * 探测异常按不支持处理——宁可得到实色界面，也不要一层糊不透的半透明底。
   */
  private static capability(): GlassMode {
    const cached = MaterialPolicy.probed;
    if (cached !== null) {
      return cached;
    }
    let mode: GlassMode = GlassMode.SOLID;
    try {
      const state = uiMaterial.getMaterialInfo().state;
      const level = uiMaterial.getGlobalMaterialLevel();
      if (uiMaterial.isImmersiveMaterialSupported()
        && state !== uiMaterial.MaterialState.DISABLE
        && level !== uiMaterial.MaterialLevel.SMOOTH) {
        mode = GlassMode.SYSTEM;
      }
    } catch (e) {
      Logger.warn(TAG, 'material probe failed, use solid: ' + (e as Error).message);
    }
    MaterialPolicy.probed = mode;
    return mode;
  }

  /** 走哪条路径的唯一出口：设备能力决定，应用侧没有可写的覆盖开关。 */
  static mode(): GlassMode {
    return MaterialPolicy.capability();
  }

  /**
   * 材质对象按强度缓存：配置不可变，避免每次重建节点时重新分配。
   * 实色路径返回 undefined，属性传 undefined 即回到无材质效果。
   */
  static material(strength: GlassStrength): uiMaterial.ImmersiveMaterial | undefined {
    if (MaterialPolicy.mode() !== GlassMode.SYSTEM) {
      return undefined;
    }
    if (strength === GlassStrength.STRONG) {
      if (MaterialPolicy.strongMaterial === null) {
        const options: uiMaterial.ImmersiveOptions = {
          style: uiMaterial.ImmersiveStyle.THICK,
          materialColor: $r('app.color.glass_strong'),
          applyShadow: true,
          interactive: false
        };
        MaterialPolicy.strongMaterial = new uiMaterial.ImmersiveMaterial(options);
      }
      return MaterialPolicy.strongMaterial;
    }
    if (MaterialPolicy.softMaterial === null) {
      const options: uiMaterial.ImmersiveOptions = {
        style: uiMaterial.ImmersiveStyle.REGULAR,
        materialColor: $r('app.color.glass_soft'),
        applyShadow: true,
        interactive: false
      };
      MaterialPolicy.softMaterial = new uiMaterial.ImmersiveMaterial(options);
    }
    return MaterialPolicy.softMaterial;
  }
}
