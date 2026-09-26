import { promptAction, ComponentContent, PromptAction, UIContext } from '@kit.ArkUI';
import { Logger } from 'commons';
import { ConfirmDialogParams, CONFIRM_DIALOG, confirmEnterTransition } from '../component/ConfirmDialog';
import { DesignTokens, MOTION_REDUCE_KEY } from '../theme/DesignTokens';
import { SCREEN_READER_KEY } from '../accessibility/AccessibilityPolicy';

/**
 * 全站确认框的统一入口：把十处 `showAlertDialog` 换成自绘面（原型 02 的 `.dlg`）。
 *
 * 三条接线口径：
 * - **落点只算一次**。按钮、遮罩、返回键可能在同一帧里竞争，settled 闩住后只认第一个；
 *   节点释放在 `onDidDisappear`（收起动画走完）里做，所以两条关闭路径共用同一个出口。
 * - **遮罩与返回键走取消那一侧**。`onWillDismiss` 一旦声明，系统就不再自己收起，必须显式
 *   `action.dismiss()`；顺带补一次取消回调——「我的·循环模板」那处的「取消」要 reloadTemplate()，
 *   点遮罩若不走它，编辑区会停在"已重置但没删"的中间态。
 * - **读屏模式回退系统确认框**。ComponentContent 的弹窗节点不保证被播报（同 AppToast 的取舍），
 *   确认框是交互入口，看不见播报就等于没有。回退版的两侧顺序与自绘版同向：取消在左、确认在右。
 */

const TAG: string = 'AppConfirm';

/** 一次确认框的文案与两条落点。 */
export interface ConfirmOptions {
  /** 省略则不画标题行（删除循环模板、删除班次×2、解除配对这四处）。 */
  title?: ResourceStr;
  message: ResourceStr;
  /** 左侧描边按钮文案，默认「取消」。 */
  cancelText?: ResourceStr;
  /** 右侧实心按钮文案。 */
  confirmText: ResourceStr;
  /** 确认侧走红：不可逆的删除/清空/解绑。 */
  danger?: boolean;
  onConfirm: () => void;
  /** 取消侧（含点遮罩与返回键）；只是关掉框时可以不传。 */
  onCancel?: () => void;
}

/** 收起动画走完再释放节点：两条关闭路径（按钮 / action.dismiss()）共用这一个出口。 */
function freeNode(node: ComponentContent<ConfirmDialogParams> | null): void {
  if (node !== null) {
    node.dispose();
  }
}

function askSystemDialog(ctx: UIContext, o: ConfirmOptions): void {
  const back = (): void => {
    if (o.onCancel !== undefined) {
      o.onCancel();
    }
  };
  const options: AlertDialogParamWithButtons = {
    message: o.message,
    primaryButton: {
      value: o.cancelText === undefined ? '取消' : o.cancelText,
      fontColor: DesignTokens.textSecondary,
      action: back
    },
    secondaryButton: {
      value: o.confirmText,
      fontColor: o.danger === true ? DesignTokens.danger : DesignTokens.primary,
      action: () => {
        o.onConfirm();
      }
    }
  };
  if (o.title !== undefined) {
    options.title = o.title;
  }
  ctx.showAlertDialog(options);
}

/** 弹一次确认框。`ctx` 由调用点的 `this.getUIContext()` 给出，与原来的 showAlertDialog 同口径。 */
export function askConfirm(ctx: UIContext, o: ConfirmOptions): void {
  if (AppStorage.get<boolean>(SCREEN_READER_KEY) === true) {
    askSystemDialog(ctx, o);
    return;
  }
  let node: ComponentContent<ConfirmDialogParams> | null = null;
  let settled = false;
  const prompt: PromptAction = ctx.getPromptAction();
  const settle = (affirm: boolean, close: () => void): void => {
    if (settled) {
      return;
    }
    settled = true;
    close();
    if (affirm) {
      o.onConfirm();
    } else if (o.onCancel !== undefined) {
      o.onCancel();
    }
  };
  const closeByButton = (): void => {
    const current: ComponentContent<ConfirmDialogParams> | null = node;
    if (current === null) {
      return;
    }
    prompt.closeCustomDialog(current)
      .catch((e: Error): void => {
        Logger.warn(TAG, 'closeCustomDialog 失败：' + e.message);
        freeNode(current);
        node = null;
      });
  };
  const params: ConfirmDialogParams = {
    title: o.title === undefined ? '' : o.title,
    message: o.message,
    cancelText: o.cancelText === undefined ? '取消' : o.cancelText,
    confirmText: o.confirmText,
    danger: o.danger === true,
    onPick: (affirm: boolean): void => {
      settle(affirm, closeByButton);
    }
  };
  node = new ComponentContent<ConfirmDialogParams>(ctx, CONFIRM_DIALOG, params);
  const opened: ComponentContent<ConfirmDialogParams> = node;
  const reduceMotion: boolean = AppStorage.get<boolean>(MOTION_REDUCE_KEY) === true;
  const options: promptAction.BaseDialogOptions = {
    autoCancel: true,
    alignment: DialogAlignment.Center,
    maskColor: DesignTokens.dlgScrim,
    dialogTransition: confirmEnterTransition(reduceMotion),
    maskTransition: TransitionEffect.OPACITY.animation({
      duration: DesignTokens.motion(reduceMotion, 200),
      curve: Curve.Sharp
    }),
    onDidDisappear: (): void => {
      freeNode(node);
      node = null;
    },
    onWillDismiss: (action: DismissDialogAction): void => {
      settle(false, (): void => {
        action.dismiss();
      });
    }
  };
  prompt.openCustomDialog(opened, options)
    .catch((e: Error): void => {
      Logger.warn(TAG, 'openCustomDialog 失败：' + e.message);
      freeNode(node);
      node = null;
    });
}
