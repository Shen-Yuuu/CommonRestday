import { promptAction, router } from '@kit.ArkUI';
import { util } from '@kit.ArkTS';
import { camera } from '@kit.CameraKit';
import { cameraPicker } from '@kit.CameraKit';
import { image } from '@kit.ImageKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { textRecognition } from '@kit.CoreVisionKit';
import { OWNER_ME, Course, ParsedCourseLine, parseCourseText, toCourse } from 'domain';
import { ScheduleRepo } from 'data';
import { Logger } from 'commons';
import { ScheduleUseCase } from 'feature';
import { ownerFromParams } from '../model/RouteParams';

const TAG = 'OcrCourse';

/** 拍照/选图 OCR 识别课程表（Core Vision Kit 端侧识别，图片不出设备；owner 双侧复用）。 */
@Entry
@Component
struct OcrCourse {
  @State owner: string = OWNER_ME;
  @State busy: boolean = false;
  @State ocrText: string = '';
  @State parsed: ParsedCourseLine[] = [];

  aboutToAppear(): void {
    this.owner = ownerFromParams(router.getParams());
  }

  /** 拍照（CameraPicker 免相机权限）。 */
  async takePhoto(): Promise<void> {
    try {
      const ctx = this.getUIContext().getHostContext();
      if (ctx == null) {
        promptAction.showToast({ message: '无法获取上下文' });
        return;
      }
      const result = await cameraPicker.pick(ctx, [cameraPicker.PickerMediaType.PHOTO], {
        cameraPosition: camera.CameraPosition.CAMERA_POSITION_BACK
      });
      if (result.resultCode === 0 && result.resultUri !== '') {
        await this.recognize(result.resultUri);
      }
    } catch (e) {
      Logger.error(TAG, 'takePhoto failed: ' + (e as Error).message);
      promptAction.showToast({ message: '拍照失败，可用相册选图' });
    }
  }

  /** 相册选图（PhotoViewPicker 免读取权限）。 */
  async pickImage(): Promise<void> {
    try {
      const picker = new photoAccessHelper.PhotoViewPicker();
      const result = await picker.select({
        MIMEType: photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE,
        maxSelectNumber: 1
      });
      if (result.photoUris.length > 0) {
        await this.recognize(result.photoUris[0]);
      }
    } catch (e) {
      Logger.error(TAG, 'pickImage failed: ' + (e as Error).message);
      promptAction.showToast({ message: '选图失败' });
    }
  }

  async recognize(uri: string): Promise<void> {
    this.busy = true;
    try {
      const source = image.createImageSource(uri);
      const pixelMap = await source.createPixelMap();
      const visionInfo: textRecognition.VisionInfo = { pixelMap: pixelMap };
      const result = await textRecognition.recognizeText(visionInfo);
      this.ocrText = result.value;
      this.parsed = parseCourseText(this.ocrText);
      pixelMap.release();
      source.release();
      if (this.parsed.length === 0) {
        promptAction.showToast({ message: '未识别到课表行，可手动核对文本后解析' });
      }
    } catch (e) {
      Logger.error(TAG, 'ocr failed: ' + (e as Error).message);
      promptAction.showToast({ message: '识别失败：' + (e as Error).message });
    }
    this.busy = false;
  }

  async saveParsed(): Promise<void> {
    let n = 0;
    for (let i = 0; i < this.parsed.length; i++) {
      if (this.parsed[i].ok) {
        await ScheduleRepo.upsertCourse(toCourse(this.parsed[i], util.generateRandomUUID()), this.owner);
        n++;
      }
    }
    promptAction.showToast({ message: '已导入 ' + n + ' 门课程' });
    // 保存动作 → 自动重算（US6 / FR-011，ME/PARTNER 两侧一致触发）
    ScheduleUseCase.onScheduleChanged().catch((e: Error) => {
      Logger.error(TAG, 'recompute failed: ' + e.message);
    });
    router.back();
  }

  build() {
    Column() {
      Row() {
        Row({ space: 2 }) {
          SymbolGlyph($r('sys.symbol.chevron_left')).fontSize(16).fontColor([$r('app.color.brand_pink')])
          Text('返回').fontSize(15).fontColor($r('app.color.brand_pink'))
        }.onClick(() => router.back())
        Blank()
        Text('拍照识别课表').fontSize(17).fontWeight(FontWeight.Bold)
        Blank()
        Text(' ')
      }.width('100%').padding(12)

      Scroll() {
        Column({ space: 12 }) {
          Row({ space: 10 }) {
            Button(this.busy ? '识别中…' : '拍照识别')
              .backgroundColor($r('app.color.info_blue')).layoutWeight(1).height(44).borderRadius(22)
              .enabled(!this.busy)
              .onClick(() => this.takePhoto())
            Button('相册选图')
              .backgroundColor($r('app.color.accent_purple')).layoutWeight(1).height(44).borderRadius(22)
              .enabled(!this.busy)
              .onClick(() => this.pickImage())
          }.width('100%')

          Text('识别在手机本地完成（Core Vision Kit），课程表图片不会上传。识别后请逐行核对再保存。')
            .fontSize(11).fontColor($r('app.color.text_hint'))

          Column({ space: 8 }) {
            Text('识别文本（可手工修正后重新解析）').fontSize(12).fontColor($r('app.color.text_tertiary')).width('100%')
            TextArea({ text: this.ocrText, placeholder: '识别结果将显示在这里' })
              .height(110).fontSize(13).width('100%')
              .onChange((v: string) => this.ocrText = v)
            Button('重新解析').height(34).backgroundColor($r('app.color.info_blue'))
              .onClick(() => this.parsed = parseCourseText(this.ocrText))
          }
          .width('100%').padding(12).borderRadius(16)
          .backgroundColor($r('app.color.card_bg'))
          .shadow({ radius: 16, color: $r('app.color.shadow_soft'), offsetX: 0, offsetY: 4 })

          ForEach(this.parsed, (p: ParsedCourseLine) => {
            Row() {
              Text(p.ok ? '✓' : '✗').fontSize(13).fontColor(p.ok ? $r('app.color.success_green') : $r('app.color.danger_red')).width(20)
              Column({ space: 2 }) {
                Text(p.ok ? p.name + ' · 周' + p.weekday + ' · 第' + p.sectionStart + '-' + p.sectionEnd
                  + '节 · ' + p.weekFrom + '-' + p.weekTo + '周' : p.rawLine)
                  .fontSize(13).fontColor($r('app.color.text_primary'))
                if (!p.ok) {
                  Text(p.error).fontSize(11).fontColor($r('app.color.danger_red'))
                }
              }.alignItems(HorizontalAlign.Start)
              Blank()
            }.width('100%').padding(8).borderRadius(8).backgroundColor($r('app.color.card_bg'))
          }, (p: ParsedCourseLine, i: number) => '' + i + p.rawLine)

          if (this.parsed.length > 0) {
            Button('保存通过项').width('100%').height(44).borderRadius(22).backgroundColor($r('app.color.success_green'))
              .onClick(() => this.saveParsed())
          }
        }
        .padding(12).width('100%')
      }
      .layoutWeight(1)
    }
    .width('100%').height('100%').backgroundColor($r('app.color.page_bg_warm'))
  }
}
