/** Complete approved silhouette (both ears and paws); only eyelids change. */
@Component
export struct CompanionActor {
  @Prop isBear: boolean = false;
  @Prop closed: boolean = false;
  private plate(): Resource {
    return this.isBear ? $r('app.media.companions_bubu_plate') : $r('app.media.companions_xiuxiu_plate');
  }
  private face(closed: boolean): Resource {
    if (this.isBear) {
      return closed ? $r('app.media.companions_bubu_face_3') : $r('app.media.companions_bubu_face_0');
    }
    return closed ? $r('app.media.companions_xiuxiu_face_3') : $r('app.media.companions_xiuxiu_face_0');
  }
  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Image(this.plate()).width(120).height(120).objectFit(ImageFit.Contain)
        .sourceSize({ width: 360, height: this.isBear ? 276 : 336 }).draggable(false)
        .hitTestBehavior(HitTestMode.None).accessibilityLevel('no')
      // Keep both decoded faces mounted; an eye blink must not wait for image loading.
      Image(this.face(false)).width(120).height(120).objectFit(ImageFit.Contain)
        .opacity(this.closed ? 0 : 1).draggable(false)
        .hitTestBehavior(HitTestMode.None).accessibilityLevel('no')
      Image(this.face(true)).width(120).height(120).objectFit(ImageFit.Contain)
        .opacity(this.closed ? 1 : 0).draggable(false)
        .hitTestBehavior(HitTestMode.None).accessibilityLevel('no')
    }.width(120).height(120).hitTestBehavior(HitTestMode.None)
  }
}
