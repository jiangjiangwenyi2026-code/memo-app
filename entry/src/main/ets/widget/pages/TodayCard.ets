/**
 * 文件路径：entry/src/main/ets/widget/pages/TodayCard.ets
 * 用途：桌面服务卡片的渲染页（独立于主界面，不在 main_pages 里注册）。
 *       版面与主界面 Index 一致：上半「近期 | 随手记」两列 + 竖分隔线，
 *       下半「时间轴」甘特横条。
 * 设计约束：
 *  - 静态卡片（isDynamic: false）不支持滚动 / 动画 / List / Scroll，
 *    装不下靠 EntryFormAbility 端预先截断（「还有 N 条…」），这里只管按行画字；
 *  - 数据全部经 LocalStorage 进来（@LocalStorageProp 的 key 与
 *    EntryFormAbility 里 createFormBindingData 的 key 一一对应），
 *    页面本身不做任何计算、不碰数据库；
 *  - 整卡可点：FormLink 以 router 方式拉起主界面 EntryAbility。
 */

let storage: LocalStorage = new LocalStorage();

/**
 * 甘特横条的高度：卡片下半区要挤下最多 5 根条，比主界面的条瘦一圈。
 * 条里的字是 10 号，行高约 13，16 的高度上下刚够留出余量。
 */
const GANTT_BAR_HEIGHT: number = 16;

/** 单日事项圆点的直径：与主界面甘特的 GANTT_POINT_SIZE 取同一个值，两处看起来才是一回事 */
const GANTT_POINT_SIZE: number = 10;

/**
 * 一根甘特横条要画的东西。
 * 为什么合成一个对象、而不是给 ganttBar 传四个基本类型参数：@Builder 按值传递时，
 * 参数只在首次渲染时取一次，之后父组件状态再变也不会重新执行它——而本卡片的真实数据
 * 是先用 placeholder 渲染一次、再由 formProvider.updateForm 二次推进来的，
 * 按值传参会让五根彩条冻在初始的空标题上，永远画不出来。对象字面量是按引用传递，
 * 每次刷新都会重新求值，彩条才跟着数据走。
 */
interface GanttBarView {
  title: string;
  left: number;
  width: number;
  /**
   * 配色档位 0-5（与主界面 GanttBarData.tint 是同一套 id 哈希，两端同一条永远同档），
   * 由下面的 barBg / barFg 映射成颜色资源。
   * **不传 hex 颜色**：卡片上要和主界面一样画成「半透明淡彩底 + 同色字」，
   * 而这一对颜色在深色主题下得整体换成另一套（浅底深字 → 深底亮字），
   * 只有 $r 资源能跟着主题切；hex 字符串在深色卡片上要么字看不见、要么还是一块死色。
   */
  tint: number;
  /** 1 = 这根是「单日事项」的圆点，0 = 普通横条。用 number 而不是 boolean：卡片数据只认基本类型 */
  point: number;
  /** 被右端截断时的「· 剩 N 天」文案（自带「· 」前缀）；空串 = 没截断，只显示标题 */
  rest: string;
}

/**
 * 卡片上半区的一条正文行（今天 / 明天 / 随手记共用）：文案 + 配色档位。
 * tint = -1 表示不上色（手写条目）。字段与 EntryFormAbility 的 LineItem 对应。
 * 同样收对象而不是两个基本类型参数——原因见上面 GanttBarView 的说明。
 */
interface LineView {
  text: string;
  tint: number;
}

@Entry(storage)
@Component
struct TodayCard {
  /**
   * 「今天」段的正文：**一条一个字段**，最多 6 条，text 和 tint 成对出现。
   * 为什么不拼成一整块多行文本：卡片上要按条目上色（课表条目用本门课的颜色），
   * 而一个 Text 只能有一个颜色，拼成一块就只能整块一个色、等于没染。
   * 字段名与 EntryFormAbility 的 putLines 一一对应；tint = -1 表示这条不上色
   * （手写条目），走正文色。上限 6 与那边的 TODAY_MAX_LINES 对齐。
   */
  @LocalStorageProp('today1Text') today1Text: string = '加载中…';
  @LocalStorageProp('today1Tint') today1Tint: number = -1;
  @LocalStorageProp('today2Text') today2Text: string = '';
  @LocalStorageProp('today2Tint') today2Tint: number = -1;
  @LocalStorageProp('today3Text') today3Text: string = '';
  @LocalStorageProp('today3Tint') today3Tint: number = -1;
  @LocalStorageProp('today4Text') today4Text: string = '';
  @LocalStorageProp('today4Tint') today4Tint: number = -1;
  @LocalStorageProp('today5Text') today5Text: string = '';
  @LocalStorageProp('today5Tint') today5Tint: number = -1;
  @LocalStorageProp('today6Text') today6Text: string = '';
  @LocalStorageProp('today6Tint') today6Tint: number = -1;
  @LocalStorageProp('todayMore') todayMore: string = '';
  /** 「明天」段：同上，最多 3 条（与那边的 TOMORROW_MAX_LINES 对齐） */
  @LocalStorageProp('tomorrow1Text') tomorrow1Text: string = '';
  @LocalStorageProp('tomorrow1Tint') tomorrow1Tint: number = -1;
  @LocalStorageProp('tomorrow2Text') tomorrow2Text: string = '';
  @LocalStorageProp('tomorrow2Tint') tomorrow2Tint: number = -1;
  @LocalStorageProp('tomorrow3Text') tomorrow3Text: string = '';
  @LocalStorageProp('tomorrow3Tint') tomorrow3Tint: number = -1;
  @LocalStorageProp('tomorrowMore') tomorrowMore: string = '';
  /** 过期段不展开，只留这一行小字；空串 = 没有过期条目，整行隐藏 */
  @LocalStorageProp('overdueText') overdueText: string = '';
  /**
   * 「下一节」那行：`13:30 · 南129`，教室没填就只有时刻。
   * 空串 = 今天没课或都上完了，整行不画（与主界面同一口径，由 EntryFormAbility 喂）。
   * 时刻和教室在数据端就拼成一整串了：卡片这一行本就窄，再拆两个字段出来
   * 就得在这里判「有没有教室」「放不放得下」，那套规则会散成两处。
   */
  @LocalStorageProp('nextText') nextText: string = '';
  /**
   * 「随手记」段：同样逐条，最多 6 条（与那边的 NOTE_MAX_LINES 对齐）。
   * 随手记不上色（tint 恒为 -1）：颜色在这套界面里是「哪门课」的标记，
   * 随手记是自己写的事、没有课可归——主界面那一列也是正文色，两边得一致。
   */
  @LocalStorageProp('note1Text') note1Text: string = '';
  @LocalStorageProp('note1Tint') note1Tint: number = -1;
  @LocalStorageProp('note2Text') note2Text: string = '';
  @LocalStorageProp('note2Tint') note2Tint: number = -1;
  @LocalStorageProp('note3Text') note3Text: string = '';
  @LocalStorageProp('note3Tint') note3Tint: number = -1;
  @LocalStorageProp('note4Text') note4Text: string = '';
  @LocalStorageProp('note4Tint') note4Tint: number = -1;
  @LocalStorageProp('note5Text') note5Text: string = '';
  @LocalStorageProp('note5Tint') note5Tint: number = -1;
  @LocalStorageProp('note6Text') note6Text: string = '';
  @LocalStorageProp('note6Tint') note6Tint: number = -1;
  @LocalStorageProp('notesMore') notesMore: string = '';
  /** 第 1 根甘特横条：标题为空串 = 这一档不存在，不渲染 */
  @LocalStorageProp('gantt1Title') gantt1Title: string = '';
  @LocalStorageProp('gantt1Left') gantt1Left: number = 0;
  @LocalStorageProp('gantt1Width') gantt1Width: number = 0;
  @LocalStorageProp('gantt1Tint') gantt1Tint: number = 0;
  @LocalStorageProp('gantt1Point') gantt1Point: number = 0;
  /** 第 1 根条被截断时的「· 剩 N 天」文案；空串 = 没截断 */
  @LocalStorageProp('gantt1Rest') gantt1Rest: string = '';
  /** 第 2 根甘特横条，机制同上 */
  @LocalStorageProp('gantt2Title') gantt2Title: string = '';
  @LocalStorageProp('gantt2Left') gantt2Left: number = 0;
  @LocalStorageProp('gantt2Width') gantt2Width: number = 0;
  @LocalStorageProp('gantt2Tint') gantt2Tint: number = 0;
  @LocalStorageProp('gantt2Point') gantt2Point: number = 0;
  @LocalStorageProp('gantt2Rest') gantt2Rest: string = '';
  /** 第 3～5 根甘特横条，机制同上。标题为空串表示这一档没有内容，不渲染 */
  @LocalStorageProp('gantt3Title') gantt3Title: string = '';
  @LocalStorageProp('gantt3Left') gantt3Left: number = 0;
  @LocalStorageProp('gantt3Width') gantt3Width: number = 0;
  @LocalStorageProp('gantt3Tint') gantt3Tint: number = 0;
  @LocalStorageProp('gantt3Point') gantt3Point: number = 0;
  @LocalStorageProp('gantt3Rest') gantt3Rest: string = '';
  @LocalStorageProp('gantt4Title') gantt4Title: string = '';
  @LocalStorageProp('gantt4Left') gantt4Left: number = 0;
  @LocalStorageProp('gantt4Width') gantt4Width: number = 0;
  @LocalStorageProp('gantt4Tint') gantt4Tint: number = 0;
  @LocalStorageProp('gantt4Point') gantt4Point: number = 0;
  @LocalStorageProp('gantt4Rest') gantt4Rest: string = '';
  @LocalStorageProp('gantt5Title') gantt5Title: string = '';
  @LocalStorageProp('gantt5Left') gantt5Left: number = 0;
  @LocalStorageProp('gantt5Width') gantt5Width: number = 0;
  @LocalStorageProp('gantt5Tint') gantt5Tint: number = 0;
  @LocalStorageProp('gantt5Point') gantt5Point: number = 0;
  @LocalStorageProp('gantt5Rest') gantt5Rest: string = '';
  @LocalStorageProp('ganttMore') ganttMore: string = '';
  @LocalStorageProp('ganttEmpty') ganttEmpty: string = '';
  /**
   * 甘特刻度三档：`9/25` `10/2` `10/9`，落在跨度的第 0 / 7 / 14 天。
   * 光有几根彩条看不出落在哪几天，标上日期才知道「这根是这两天的事」。
   * 位置与条的百分比同一套换算（都在 EntryFormAbility 里按 CARD_GANTT_DAYS 算），
   * 两边对齐才对得上——所以这里只是把三串字摆到左 / 中 / 右，不自己算位置。
   */
  @LocalStorageProp('tick1') tick1: string = '';
  @LocalStorageProp('tick2') tick2: string = '';
  @LocalStorageProp('tick3') tick3: string = '';

  /**
   * 画一根甘特条：一个透明占位列（把条推到正确的日期位置）+ 条本身。
   * 宽度按百分比定位，换算在 EntryFormAbility 里做好，与主界面甘特同一套规则。
   * 标题为空串时不画——EntryFormAbility 用空标题表示「这一档没有内容」。
   * 参数收一个对象而不是四个基本类型，原因见 GanttBarView 的说明。
   * 两种画法与主界面一致（见 Index.ets 的 ganttBar / ganttPoint）：
   *   普通横条 → 名字写在条里；单日事项（point=1）→ 一个圆点 + 名字写在点外面。
   * 卡片比主界面窄得多，点里更塞不下字（0.35 天 ≈ 卡片宽度的 1%），
   * 不换这种画法的话，卡片上就只是一粒「不知道是什么事」的小色点。
   */

  /**
   * 条上文案：被右端截断的条在标题后拼「· 剩 N 天」（rest 已带「· 」前缀），
   * 与全屏甘特的 barLabel 同一口径；没截断就只显示标题。
   */
  barLabel(bar: GanttBarView): string {
    return bar.rest.length > 0 ? `${bar.title}${bar.rest}` : bar.title;
  }

  /**
   * 配色档位 → 条的底色（半透明淡彩）/ 文字色（同色的深一档）。
   * 与主界面同一套路数（见 Index.ets 的 barBg / barFg），色值也取同一批资源，
   * 所以桌面上这张卡片和 App 里的时间轴看起来是一回事。
   * 底色半透明、字用同色而不是白色：白字压在浅色底上会糊，深色主题下又反过来。
   */
  barBg(tint: number): Resource {
    if (tint === 0) { return $r('app.color.bar_0_bg'); }
    if (tint === 1) { return $r('app.color.bar_1_bg'); }
    if (tint === 2) { return $r('app.color.bar_2_bg'); }
    if (tint === 3) { return $r('app.color.bar_3_bg'); }
    if (tint === 4) { return $r('app.color.bar_4_bg'); }
    return $r('app.color.bar_5_bg');
  }

  barFg(tint: number): Resource {
    if (tint === 0) { return $r('app.color.bar_0_fg'); }
    if (tint === 1) { return $r('app.color.bar_1_fg'); }
    if (tint === 2) { return $r('app.color.bar_2_fg'); }
    if (tint === 3) { return $r('app.color.bar_3_fg'); }
    if (tint === 4) { return $r('app.color.bar_4_fg'); }
    return $r('app.color.bar_5_fg');
  }

  /**
   * 课程配色档位 → 字色（course_0..5_fg）；tint < 0 = 手写条目，走正文色。
   * 与主界面同一批资源（见 Index.ets 的 courseFg），同一门课在卡片和 App 里是同一个颜色。
   * 卡片上**只染字、不铺底色块**：卡片高度是死的，每行再加一层块和内边距，
   * 就得有内容被挤出卡片——反过来，只换字色不占一点篇幅。
   */
  courseFg(tint: number): Resource {
    if (tint === 0) { return $r('app.color.course_0_fg'); }
    if (tint === 1) { return $r('app.color.course_1_fg'); }
    if (tint === 2) { return $r('app.color.course_2_fg'); }
    if (tint === 3) { return $r('app.color.course_3_fg'); }
    if (tint === 4) { return $r('app.color.course_4_fg'); }
    if (tint === 5) { return $r('app.color.course_5_fg'); }
    return $r('app.color.text_primary');
  }

  /**
   * 一条正文行：课表条目用本门课的颜色、加粗半点，手写条目用正文色。
   * 上限两行与主界面「近期」同一考虑：卡片列窄，长标题得折一行才看得全，
   * 但最多两行——再多就把下面的条目顶出去了。
   */
  @Builder
  cardLine(row: LineView) {
    Text(row.text)
      .fontSize(12)
      .fontColor(this.courseFg(row.tint))
      .fontWeight(row.tint >= 0 ? FontWeight.Medium : FontWeight.Normal)
      .maxLines(2)
      .textOverflow({ overflow: TextOverflow.Ellipsis })
      .margin({ top: 2 })
  }

  @Builder
  ganttBar(bar: GanttBarView) {
    if (bar.title.length > 0) {
      Row() {
        Column()
          .width(`${bar.left}%`)
        if (bar.point === 1) {
          // 点靠右时名字改放左边：卡片窄，右边余下的宽度常常不够写字
          if (bar.left > 50) {
            Text(this.barLabel(bar))
              .fontSize(10)
              .fontColor($r('app.color.text_primary'))
              .textAlign(TextAlign.End)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
              .margin({ right: 4 })
            this.ganttDot(bar.tint)
          } else {
            this.ganttDot(bar.tint)
            Text(this.barLabel(bar))
              .fontSize(10)
              .fontColor($r('app.color.text_primary'))
              .textAlign(TextAlign.Start)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
              .margin({ left: 4 })
          }
        } else {
          Text(this.barLabel(bar))
            .fontSize(10)
            .fontColor(this.barFg(bar.tint))
            .textAlign(TextAlign.Center)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .height(GANTT_BAR_HEIGHT)
            .borderRadius(GANTT_BAR_HEIGHT / 2)
            .backgroundColor(this.barBg(bar.tint))
            .width(`${bar.width}%`)
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .margin({ top: 5 })
    }
  }

  /**
   * 单日事项的圆点，尺寸与主界面甘特的点对齐（见 Index.ets 的 GANTT_POINT_SIZE）。
   * 点用**实色**那一档（barFg）而不是横条那种半透明底色：点只有 10vp，
   * 淡淡的颜色铺在卡片背景上就找不着了——横条够宽才经得起半透明。
   */
  @Builder
  ganttDot(tint: number) {
    Column()
      .width(GANTT_POINT_SIZE)
      .height(GANTT_POINT_SIZE)
      .borderRadius(GANTT_POINT_SIZE / 2)
      .backgroundColor(this.barFg(tint))
  }

  build() {
    // FormLink 包住整张卡：点任意位置都拉起主界面（静态卡片唯一的跳转方式）
    FormLink({
      action: 'router',
      abilityName: 'EntryAbility',
      params: { 'from': 'todayCard' }
    }) {
      Column() {
        // ── 上半：左「近期」右「随手记」，版面与主界面一致 ──
        Row() {
          // 左列：近期（今天 / 明天展开，过期只留一行计数）
          Column() {
            Text('近期')
              .fontSize(14)
              .fontColor($r('app.color.text_primary'))
              .fontWeight(FontWeight.Medium)
            // 「下一节」：今天还有没上的课就顶在「今天」上面，与主界面同一位置。
            // 时刻用正文色加粗：这一行扫一眼要看的是几点，不是「下一节」三个字。
            // 地点跟着时刻同一串（见 nextText 的说明），太长就省略号，不折行——
            // 卡片高度是死的，多折一行就会把下面的条目挤没
            if (this.nextText.length > 0) {
              Row({ space: 4 }) {
                Text('下一节')
                  .fontSize(10)
                  .fontColor($r('app.color.text_secondary'))
                Text(this.nextText)
                  .fontSize(11)
                  .fontColor($r('app.color.text_primary'))
                  .fontWeight(FontWeight.Medium)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .layoutWeight(1)
              }
              .width('100%')
              .alignItems(VerticalAlign.Center)
              .margin({ top: 6 })
            }
            // 每条一个 Text 各染各的颜色，见 today1Tint 的说明。
            // 空串 = 这一档没内容，不画（putLines 每次都把六档推满，不会留旧值）
            if (this.today1Text.length > 0) {
              Text('今天')
                .fontSize(11)
                .fontColor($r('app.color.text_secondary'))
                .margin({ top: 6 })
              this.cardLine({ text: this.today1Text, tint: this.today1Tint })
            }
            if (this.today2Text.length > 0) {
              this.cardLine({ text: this.today2Text, tint: this.today2Tint })
            }
            if (this.today3Text.length > 0) {
              this.cardLine({ text: this.today3Text, tint: this.today3Tint })
            }
            if (this.today4Text.length > 0) {
              this.cardLine({ text: this.today4Text, tint: this.today4Tint })
            }
            if (this.today5Text.length > 0) {
              this.cardLine({ text: this.today5Text, tint: this.today5Tint })
            }
            if (this.today6Text.length > 0) {
              this.cardLine({ text: this.today6Text, tint: this.today6Tint })
            }
            if (this.todayMore.length > 0) {
              Text(this.todayMore)
                .fontSize(10)
                .fontColor($r('app.color.text_secondary'))
                .margin({ top: 2 })
            }
            if (this.tomorrow1Text.length > 0) {
              Text('明天')
                .fontSize(11)
                .fontColor($r('app.color.text_secondary'))
                .margin({ top: 6 })
              this.cardLine({ text: this.tomorrow1Text, tint: this.tomorrow1Tint })
            }
            if (this.tomorrow2Text.length > 0) {
              this.cardLine({ text: this.tomorrow2Text, tint: this.tomorrow2Tint })
            }
            if (this.tomorrow3Text.length > 0) {
              this.cardLine({ text: this.tomorrow3Text, tint: this.tomorrow3Tint })
            }
            if (this.tomorrowMore.length > 0) {
              Text(this.tomorrowMore)
                .fontSize(10)
                .fontColor($r('app.color.text_secondary'))
                .margin({ top: 2 })
            }
            if (this.overdueText.length > 0) {
              Text(this.overdueText)
                .fontSize(10)
                .fontColor($r('app.color.text_secondary'))
                .margin({ top: 6 })
            }
          }
          .layoutWeight(1)
          .height('100%')
          .padding({ left: 12, right: 8, top: 12, bottom: 12 })
          .alignItems(HorizontalAlign.Start)

          // 两列之间的竖分隔线，与主界面同一根细线样式
          Divider()
            .vertical(true)
            .height('100%')
            .color($r('app.color.border'))

          // 右列：随手记
          Column() {
            Text('随手记')
              .fontSize(14)
              .fontColor($r('app.color.text_primary'))
              .fontWeight(FontWeight.Medium)
            if (this.note1Text.length > 0) {
              this.cardLine({ text: this.note1Text, tint: this.note1Tint })
            }
            if (this.note2Text.length > 0) {
              this.cardLine({ text: this.note2Text, tint: this.note2Tint })
            }
            if (this.note3Text.length > 0) {
              this.cardLine({ text: this.note3Text, tint: this.note3Tint })
            }
            if (this.note4Text.length > 0) {
              this.cardLine({ text: this.note4Text, tint: this.note4Tint })
            }
            if (this.note5Text.length > 0) {
              this.cardLine({ text: this.note5Text, tint: this.note5Tint })
            }
            if (this.note6Text.length > 0) {
              this.cardLine({ text: this.note6Text, tint: this.note6Tint })
            }
            if (this.notesMore.length > 0) {
              Text(this.notesMore)
                .fontSize(10)
                .fontColor($r('app.color.text_secondary'))
                .margin({ top: 2 })
            }
            if (this.note1Text.length === 0) {
              Text('还没有随手记')
                .fontSize(10)
                .fontColor($r('app.color.text_secondary'))
                .margin({ top: 6 })
            }
          }
          .layoutWeight(1)
          .height('100%')
          .padding({ left: 8, right: 12, top: 12, bottom: 12 })
          .alignItems(HorizontalAlign.Start)
        }
        .layoutWeight(1)
        .width('100%')
        // 兜底裁剪：上半区高度是 layoutWeight(1) 算出来的死值，里面的两列又都是 height('100%')，
        // 内容一旦比它高，ArkUI 默认不裁剪、直接画到父容器外面——2026-09-28 用户报的
        // 「冲突重叠」就是「明天」段整段压到了下半区的「时间轴」标题上。
        // 真正的容量控制在数据端（CARD_TODAY_MAX / CARD_TOMORROW_MAX 折叠条目），
        // 这一行是第二道保险：哪天口径又对不上，宁可截掉半行字，也不要两段文字糊在一起。
        .clip(true)

        // 上下半之间的横分隔线，与主界面同款
        Divider()
          .width('100%')
          .color($r('app.color.border'))

        // ── 下半：时间轴甘特（最多五根横条，多的折成一行小字） ──
        Column() {
          Text('时间轴')
            .fontSize(14)
            .fontColor($r('app.color.text_primary'))
            .fontWeight(FontWeight.Medium)
          // 刻度行：左 / 中 / 右三档，与主界面一样标在条的上方。
          // 中间那档用 layoutWeight 顶到剩余宽度里居中，两端各按各的对齐——
          // 不这么写就得算绝对坐标，而卡片宽度随规格（4*4 / 6*4）变，算出来也是白算
          if (this.tick1.length > 0) {
            Row() {
              Text(this.tick1)
                .fontSize(9)
                .fontColor($r('app.color.text_secondary'))
              Text(this.tick2)
                .fontSize(9)
                .fontColor($r('app.color.text_secondary'))
                .textAlign(TextAlign.Center)
                .layoutWeight(1)
              Text(this.tick3)
                .fontSize(9)
                .fontColor($r('app.color.text_secondary'))
                .textAlign(TextAlign.End)
            }
            .width('100%')
            .margin({ top: 4 })
          }
          // 逐根传对象字面量（按引用），数据刷新时这里会重新求值，见 GanttBarView 的说明
          this.ganttBar({
            title: this.gantt1Title, left: this.gantt1Left,
            width: this.gantt1Width, tint: this.gantt1Tint,
            point: this.gantt1Point, rest: this.gantt1Rest
          })
          this.ganttBar({
            title: this.gantt2Title, left: this.gantt2Left,
            width: this.gantt2Width, tint: this.gantt2Tint,
            point: this.gantt2Point, rest: this.gantt2Rest
          })
          this.ganttBar({
            title: this.gantt3Title, left: this.gantt3Left,
            width: this.gantt3Width, tint: this.gantt3Tint,
            point: this.gantt3Point, rest: this.gantt3Rest
          })
          this.ganttBar({
            title: this.gantt4Title, left: this.gantt4Left,
            width: this.gantt4Width, tint: this.gantt4Tint,
            point: this.gantt4Point, rest: this.gantt4Rest
          })
          this.ganttBar({
            title: this.gantt5Title, left: this.gantt5Left,
            width: this.gantt5Width, tint: this.gantt5Tint,
            point: this.gantt5Point, rest: this.gantt5Rest
          })
          if (this.ganttMore.length > 0) {
            Text(this.ganttMore)
              .fontSize(10)
              .fontColor($r('app.color.text_secondary'))
              .margin({ top: 4 })
          }
          if (this.ganttEmpty.length > 0) {
            Text(this.ganttEmpty)
              .fontSize(10)
              .fontColor($r('app.color.text_secondary'))
              .margin({ top: 8 })
          }
        }
        .width('100%')
        .padding({ left: 12, right: 12, top: 10, bottom: 12 })
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.bg_card'))
    }
    .width('100%')
    .height('100%')
  }
}
