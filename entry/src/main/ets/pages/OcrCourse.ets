import { router } from '@kit.ArkUI';
import { util } from '@kit.ArkTS';
import { camera, cameraPicker } from '@kit.CameraKit';
import { fileIo } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { textRecognition } from '@kit.CoreVisionKit';
import { OWNER_ME, Course, ParsedCourseLine, parseCourseImageText, toCourse } from 'domain';
import { Logger } from 'commons';
import { ScheduleCommandService } from 'feature';
import { ownerFromParams, courseImageSource } from '../model/RouteParams';
import { DesignTokens } from '../theme/DesignTokens';
import { toastCommand } from '../util/CommandToast';
import { appToast } from '../util/AppToast';

const TAG = 'OcrCourse';
const MAX_IMAGE_EDGE = 4096;

/** 相册/拍照只读用户选择的图片；端侧识别、手工核对后才写课程。 */
@Entry
@Component
struct OcrCourse {
  @State owner: string = OWNER_ME;
  @State busy: boolean = false;
  @State saving: boolean = false;
  @State ocrText: string = '';
  @State imageUri: string = '';
  @State statusText: string = '';
  @State confirmed: boolean = false;
  @State parsed: ParsedCourseLine[] = [];
  private alive: boolean = false;
  private autoStarted: boolean = false;
  private requestedSource: string = '';

  aboutToAppear(): void {
    const params = router.getParams();
    this.owner = ownerFromParams(params);
    this.requestedSource = courseImageSource(params);
    this.alive = true;
  }

  aboutToDisappear(): void { this.alive = false; }

  private startRequestedImport(): void {
    if (this.autoStarted) { return; }
    this.autoStarted = true;
    if (this.requestedSource === 'album') { this.pickImage(); }
    if (this.requestedSource === 'camera') { this.takePhoto(); }
  }

  async takePhoto(): Promise<void> {
    if (this.busy || this.saving) { return; }
    this.busy = true;
    this.statusText = '请拍摄清晰、完整的课表';
    try {
      const ctx = this.getUIContext().getHostContext();
      if (ctx == null) { throw new Error('context unavailable'); }
      const result = await cameraPicker.pick(ctx, [cameraPicker.PickerMediaType.PHOTO], {
        cameraPosition: camera.CameraPosition.CAMERA_POSITION_BACK
      });
      if (!this.alive) { return; }
      if (result.resultCode === 0 && result.resultUri !== '') {
        await this.recognize(result.resultUri);
      } else { this.statusText = ''; }
    } catch (_) {
      if (this.alive) { this.statusText = '拍照未完成，可以重试或从相册选图。'; }
      Logger.warn(TAG, 'camera import did not complete');
    } finally {
      if (this.alive) { this.busy = false; }
    }
  }

  async pickImage(): Promise<void> {
    if (this.busy || this.saving) { return; }
    this.busy = true;
    this.statusText = '请选择一张课表图片';
    try {
      const picker = new photoAccessHelper.PhotoViewPicker();
      const result = await picker.select({
        MIMEType: photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE, maxSelectNumber: 1
      });
      if (!this.alive) { return; }
      if (result.photoUris.length > 0) {
        await this.recognize(result.photoUris[0]);
      } else { this.statusText = ''; }
    } catch (_) {
      if (this.alive) { this.statusText = '相册选图未完成，请重新选择。'; }
      Logger.warn(TAG, 'album import did not complete');
    } finally {
      if (this.alive) { this.busy = false; }
    }
  }

  private async recognize(uri: string): Promise<void> {
    let file: fileIo.File | undefined = undefined;
    let source: image.ImageSource | undefined = undefined;
    let pixelMap: image.PixelMap | undefined = undefined;
    let initialized = false;
    this.confirmed = false;
    this.parsed = [];
    this.imageUri = uri;
    this.statusText = '正在手机上识别文字…';
    try {
      // 相册返回授权 URI，必须先通过文件描述符读取。
      file = await fileIo.open(uri, fileIo.OpenMode.READ_ONLY);
      source = image.createImageSource(file.fd);
      const info = await source.getImageInfo();
      const edge = Math.max(info.size.width, info.size.height);
      if (edge <= 0) { throw new Error('invalid image size'); }
      const scale = Math.min(1, MAX_IMAGE_EDGE / edge);
      pixelMap = await source.createPixelMap({
        desiredPixelFormat: image.PixelMapFormat.RGBA_8888,
        desiredSize: { width: Math.max(1, Math.round(info.size.width * scale)),
          height: Math.max(1, Math.round(info.size.height * scale)) }
      });
      initialized = await textRecognition.init();
      if (!initialized) { throw new Error('OCR unavailable'); }
      if (!this.alive) { return; }
      const result = await textRecognition.recognizeText({ pixelMap: pixelMap });
      if (!this.alive) { return; }
      this.ocrText = result.value;
      this.parsed = parseCourseImageText(this.ocrText);
      this.statusText = result.value.trim() === '' ? '没有识别到文字，请换一张清晰图片。'
        : '文字已提取。网格课表可能缺少星期或节次，请对照图片补全，再重新解析。';
    } catch (_) {
      if (this.alive) {
        this.statusText = '本次识别未完成。可换图重试，或在下方粘贴、整理文字；原文字仍保留。';
      }
      Logger.warn(TAG, 'local OCR did not complete');
    } finally {
      // 所有错误与返回路径都释放资源，清理失败不覆盖已取得的草稿。
      if (pixelMap !== undefined) { try { await pixelMap.release(); } catch (_) {} }
      if (source !== undefined) { try { await source.release(); } catch (_) {} }
      if (file !== undefined) { try { await fileIo.close(file); } catch (_) {} }
      if (initialized) { try { await textRecognition.release(); } catch (_) {} }
    }
  }

  private validCount(): number {
    return this.parsed.filter((row: ParsedCourseLine) => row.ok).length;
  }

  private reparse(): void {
    if (this.busy || this.saving) { return; }
    this.confirmed = false;
    this.parsed = parseCourseImageText(this.ocrText);
  }

  async saveParsed(): Promise<void> {
    if (this.busy || this.saving || !this.confirmed || this.validCount() === 0) { return; }
    const list: Course[] = [];
    for (let i = 0; i < this.parsed.length; i++) {
      if (this.parsed[i].ok) { list.push(toCourse(this.parsed[i], util.generateRandomUUID())); }
    }
    this.saving = true;
    try {
      const result = await ScheduleCommandService.importCourses(list, this.owner);
      if (!this.alive) { return; }
      toastCommand(result, '已导入 ' + list.length + ' 门课程');
      if (result.ok) { router.back(); }
    } catch (_) {
      if (this.alive) { appToast('保存未完成，核对结果已保留，可以重试'); }
    } finally {
      if (this.alive) { this.saving = false; }
    }
  }

  build() {
    Column() {
      Row() {
        Button('返回').fontSize(14).fontColor(DesignTokens.textAccent)
          .backgroundColor(Color.Transparent).constraintSize({ minHeight: 44 })
          .enabled(!this.saving).onClick(() => router.back())
        Text(this.owner === OWNER_ME ? '图片导入课表' : 'TA 的图片课表')
          .fontSize(17).fontWeight(FontWeight.Bold).fontColor(DesignTokens.textPrimary)
          .layoutWeight(1).textAlign(TextAlign.Center)
        Blank().width(64)
      }.width('100%').padding({ left: 8, right: 8 })

      Scroll() {
        Column({ space: 12 }) {
          Row({ space: 10 }) {
            Button('相册选图').layoutWeight(1).constraintSize({ minHeight: 44 })
              .fontSize(14).fontWeight(FontWeight.Bold)
              .backgroundColor(DesignTokens.primaryBg).fontColor(DesignTokens.textAccent)
              .enabled(!this.busy && !this.saving).onClick(() => this.pickImage())
            Button('拍照识别').layoutWeight(1).constraintSize({ minHeight: 44 })
              .fontSize(14).backgroundColor(DesignTokens.fillWeak).fontColor(DesignTokens.textPrimary)
              .enabled(!this.busy && !this.saving).onClick(() => this.takePhoto())
          }.width('100%')
          Text('图片只在手机上识别，不上传。核对星期、节次和周次后再保存；学期起点和每节时间沿用课程表设置。')
            .fontSize(12).fontColor(DesignTokens.textSecondary).width('100%')
          if (this.statusText !== '') {
            Text(this.statusText).fontSize(12).fontColor(DesignTokens.textSecondary).width('100%')
              .padding(10).backgroundColor(DesignTokens.fillWeakest).borderRadius(10)
          }
          if (this.imageUri !== '') {
            Image(this.imageUri).width('100%').height(160).objectFit(ImageFit.Contain)
              .borderRadius(12).accessibilityText('所选课表图片，供核对识别文字')
          }
          Column({ space: 8 }) {
            Text('核对文字').fontSize(15).fontWeight(FontWeight.Bold)
              .fontColor(DesignTokens.textPrimary).width('100%')
            Text('每行一门，例如：高等数学 周一 第1-2节 1-16周 单周')
              .fontSize(12).fontColor(DesignTokens.textSecondary).width('100%')
            TextArea({ text: this.ocrText, placeholder: '识别结果会显示在这里，也可以粘贴、整理课表文字' })
              .height(150).fontSize(13).width('100%').fontColor(DesignTokens.textPrimary)
              .backgroundColor(DesignTokens.fillWeakest).borderRadius(DesignTokens.radiusInput)
              .enabled(!this.busy && !this.saving)
              .onChange((value: string) => {
                if (value !== this.ocrText) {
                  this.ocrText = value;
                  this.parsed = [];
                  this.confirmed = false;
                }
              })
            Button('重新解析').constraintSize({ minHeight: 44 }).fontSize(14)
              .backgroundColor(DesignTokens.fillWeak).fontColor(DesignTokens.textPrimary)
              .enabled(!this.busy && !this.saving && this.ocrText.trim() !== '')
              .onClick(() => this.reparse())
          }.width('100%').padding(12).alignItems(HorizontalAlign.Start)
            .borderRadius(DesignTokens.cardRadius(false)).backgroundColor(DesignTokens.card)

          ForEach(this.parsed, (row: ParsedCourseLine) => {
            Column({ space: 4 }) {
              Text(row.ok ? row.name + ' · 周' + row.weekday + ' · 第' + row.sectionStart + '-' + row.sectionEnd
                + '节 · ' + row.weekFrom + '-' + row.weekTo + '周 · '
                + (row.parity === 1 ? '单周' : row.parity === 2 ? '双周' : '每周') : row.rawLine)
                .fontSize(13).fontColor(DesignTokens.textPrimary).width('100%')
              Text(row.ok ? '可导入' : row.error).fontSize(12).fontColor(DesignTokens.textSecondary).width('100%')
            }.width('100%').padding(12).borderRadius(12).backgroundColor(DesignTokens.card)
          }, (row: ParsedCourseLine, index: number) => '' + index + row.rawLine)

          if (this.parsed.length > 0) {
            Text('可导入 ' + this.validCount() + ' 门，待补全 ' + (this.parsed.length - this.validCount()) + ' 行')
              .fontSize(13).fontColor(DesignTokens.textPrimary).width('100%')
            Row({ space: 8 }) {
              Checkbox().select(this.confirmed).enabled(!this.busy && !this.saving && this.validCount() > 0)
                .onChange((value: boolean) => { this.confirmed = value; })
                .accessibilityText('我已核对课程的星期、节次和周次')
              Text('我已核对星期、节次和周次').fontSize(13).fontColor(DesignTokens.textPrimary).layoutWeight(1)
            }.width('100%').constraintSize({ minHeight: 44 })
            Button(this.saving ? '保存中…' : '保存已核对课程（' + this.validCount() + '）')
              .width('100%').constraintSize({ minHeight: 44 }).fontSize(14).fontWeight(FontWeight.Bold)
              .backgroundColor(DesignTokens.successAction).fontColor(DesignTokens.heroText)
              .enabled(!this.busy && !this.saving && this.confirmed && this.validCount() > 0)
              .onClick(() => this.saveParsed())
          }
        }.padding({ left: 16, right: 16, top: 8, bottom: 32 }).width('100%')
      }.layoutWeight(1).width('100%').scrollBar(BarState.Off)
    }.width('100%').height('100%').linearGradient(DesignTokens.pageGradient())
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
      .onAppear(() => this.startRequestedImport())
  }
}
