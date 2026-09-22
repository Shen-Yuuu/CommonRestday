let storage = new LocalStorage();

/**
 * 2x2 服务卡片（ArkTS Card 限制子集，US7 / FR-013，阶段 4 Task 4.2）。
 *
 * 卡面六态由 feature 的 CardSummaryService 投影后按 JSON 键下发：
 * 空串是"正在计算"，其余六态分别是今晚可见 / 下个完整同休日 / 暂无结果 /
 * 未录日程 / 数据过期 / 配对待同步。卡片只渲染下发的字符串，不做任何判断，
 * 所以这里的 state 字面量必须与 CardState 的取值一致（卡片进程不加载 feature 模块，
 * 只能重写字面量——改一边就得改另一边，两处都有注释互指）。
 *
 * 限制：卡片仅支持装饰器子集（@Entry/@Component/@LocalStorageProp），禁用
 * @Watch/@Link/@Provide 等高级特性；色值直接写字面量；不展示完整班表。
 */
@Entry(storage)
@Component
struct RestCard2x2 {
  @LocalStorageProp('state') state: string = '';
  @LocalStorageProp('question') question: string = '同休日';
  @LocalStorageProp('hero') hero: string = '正在计算…';
  @LocalStorageProp('heroNote') heroNote: string = '';
  @LocalStorageProp('second') second: string = '';
  @LocalStorageProp('footer') footer: string = '';
  @LocalStorageProp('route') route: string = 'home';

  build() {
    Column({ space: 5 }) {
      Text(this.question)
        .fontSize(11)
        .fontColor('#FFFFFF')
        .opacity(0.88)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })

      Text(this.hero)
        .fontSize(19)
        .fontWeight(FontWeight.Bold)
        .fontColor('#FFFFFF')
        .lineHeight(24)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })

      if (this.heroNote !== '') {
        Text(this.heroNote)
          .fontSize(11)
          .fontColor('#FFFFFF')
          .opacity(0.92)
          .lineHeight(15)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }

      if (this.second !== '') {
        Divider()
          .strokeWidth(0.6)
          .color('#FFFFFF')
          .opacity(0.35)
          .margin({ top: 1, bottom: 1 })
        Text(this.second)
          .fontSize(11)
          .fontColor('#FFFFFF')
          .opacity(0.95)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }

      Blank()

      if (this.footer !== '') {
        Text(this.footer)
          .fontSize(10)
          .fontColor('#FFFFFF')
          .opacity(0.8)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
    }
    .width('100%')
    .height('100%')
    .padding({ left: 14, right: 14, top: 12, bottom: 12 })
    .alignItems(HorizontalAlign.Start)
    .justifyContent(FlexAlign.Start)
    .linearGradient({
      angle: 135,
      colors: [['#D24A7E', 0.0], ['#E8833A', 1.0]]
    })
    .onClick(() => {
      // route 由卡片数据下发（只可能是 NavRoutes 白名单里的名字）：
      // 壳层落地前还会按白名单再验一次，进程外参数不当作可信输入
      postCardAction(this, {
        'action': 'router',
        'abilityName': 'EntryAbility',
        'params': {
          'route': this.route
        }
      });
    })
  }
}
