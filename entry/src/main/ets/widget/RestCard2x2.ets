let storage = new LocalStorage();

/**
 * 2x2 服务卡片（ArkTS Card 限制子集，US7 / FR-013）：
 * 标题（下次同休/我的下次休息）+ 倒计时天数大字 + 次窗口摘要；
 * 点击整卡 postCardAction router 回到首页（EntryAbility）。
 * 注意：卡片仅支持装饰器子集（@Entry/@Component/@LocalStorageProp），
 * 禁用 @Watch/@Link/@Provide 等高级特性；色值直接写字面量。
 */
@Entry(storage)
@Component
struct RestCard2x2 {
  @LocalStorageProp('title') title: string = '下次同休';
  @LocalStorageProp('days') days: number = -1;
  @LocalStorageProp('dateText') dateText: string = '';
  @LocalStorageProp('windowText') windowText: string = '正在计算…';
  @LocalStorageProp('hasPartner') hasPartner: boolean = false;

  build() {
    Column({ space: 6 }) {
      Text(this.title)
        .fontSize(12)
        .fontColor('#FFFFFF')
        .opacity(0.9)
        .maxLines(1)

      if (this.days > 0) {
        Row({ space: 3 }) {
          Text('' + this.days)
            .fontSize(40)
            .fontWeight(FontWeight.Bold)
            .fontColor('#FFFFFF')
            .maxLines(1)
          Text(' 天后')
            .fontSize(13)
            .fontColor('#FFFFFF')
            .opacity(0.9)
        }
        .alignItems(VerticalAlign.Bottom)
        .width('100%')
      } else if (this.days === 0) {
        Text('就是今天')
          .fontSize(30)
          .fontWeight(FontWeight.Bold)
          .fontColor('#FFFFFF')
          .maxLines(1)
      } else {
        Text('暂无窗口')
          .fontSize(20)
          .fontWeight(FontWeight.Medium)
          .fontColor('#FFFFFF')
          .maxLines(1)
      }

      if (this.days >= 0) {
        if (this.dateText !== '') {
          Text(this.dateText)
            .fontSize(12)
            .fontColor('#FFFFFF')
            .opacity(0.95)
            .maxLines(1)
        }
        if (this.windowText !== '') {
          Text(this.windowText)
            .fontSize(11)
            .fontColor('#FFFFFF')
            .opacity(0.85)
            .maxLines(1)
        }
      } else {
        Text(this.hasPartner ? '打开 App 录入双方课表后自动重算' : '打开 App 添加伴侣，解锁共同时间')
          .fontSize(11)
          .fontColor('#FFFFFF')
          .opacity(0.85)
          .maxLines(2)
      }
    }
    .width('100%')
    .height('100%')
    .padding({ left: 16, right: 16, top: 14, bottom: 14 })
    .alignItems(HorizontalAlign.Start)
    .justifyContent(FlexAlign.Center)
    .linearGradient({
      angle: 135,
      colors: [['#D24A7E', 0.0], ['#E8833A', 1.0]]
    })
    .onClick(() => {
      postCardAction(this, {
        'action': 'router',
        'abilityName': 'EntryAbility',
        'params': {}
      });
    })
  }
}
