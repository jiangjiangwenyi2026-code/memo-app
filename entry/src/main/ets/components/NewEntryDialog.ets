/**
 * 文件路径：entry/src/main/ets/components/NewEntryDialog.ets
 * 用途：全 App 统一的「新建 / 编辑条目」弹窗卡。新建有四个入口（近期·今天 / 近期·明天 /
 *       随手记 / 时间轴），编辑由甘特条点击进入；共用这一个组件，差别只在打开时的预填值。
 * 实现说明：故意沿用 TimetablePage 的取舍、不用 @CustomDialog——四个入口的预填值各不相同，
 *       CustomDialog 的 builder 参数在构造时绑定、二次打开预填值容易不刷新；
 *       改由页面用模态遮罩 + if 条件挂载本组件，每次打开都重建一遍组件，
 *       预填值走普通成员传入、aboutToAppear 里落进 @State，预填 / 重置都可控。
 * 语义（重要）：
 *       「需要提前准备」开关关 = 单日事项：只有日期、没有开始日，甘特上画一个点；
 *       开关开 = 长期任务：有开始日（默认今天），甘特上画一根横条。
 *       为什么要让用户显式拨一次开关：光靠开始日填没填区分不了两者——
 *       约定里长期任务没填开始日会自动写今天，数据上会和单日事项混掉。
 */

import { startOfDay } from '../viewmodel/EntryDisplay';

@Component
export struct NewEntryDialog {
  /** 打开时预填的日期（0 点时间戳）；null = 无日期（随手记入口的默认形态） */
  initialDate: number | null = null;
  /** 「需要提前准备」开关的初值：开 = 长期任务，关 = 单日事项 */
  initialNeedPrep: boolean = false;
  /** 是否编辑已有条目：true 时标题变「改一条」、按钮区多一个删除 */
  isEdit: boolean = false;
  /** 编辑时预填进输入框的内容；新建时传空串 */
  initialText: string = '';
  /** 编辑长期任务时预填的「从哪天开始准备」；0 = 没传，打开时退回今天 */
  initialPrepDate: number = 0;
  /** 编辑时预填的截止时刻（绝对时间戳）；0 = 本来就没设。新建时一律不传 */
  initialDueTime: number = 0;
  /** 删除回调：只在 isEdit 为 true 时有意义 */
  onDelete: () => void = () => {
  };
  /**
   * 保存回调：(内容, 日期, 开始日, 截止时刻)。开关关时开始日恒为 null，开时为「从哪天开始准备」
   * 选中的日子（用户没动过就是今天）。截止时刻依附于日期：日期为空时恒为 null。
   * 写库前的归一化由页面统一做，弹窗只交值。
   */
  onConfirm: (text: string, date: number | null, startDate: number | null,
    dueTime: number | null) => void = () => {
  };
  /** 取消回调：弹窗不自己管可见性，交回页面关掉即可 */
  onCancel: () => void = () => {
  };

  /** 输入框当前内容 */
  @State text: string = '';
  /** 当前选中的日期；null = 无日期 */
  @State date: number | null = null;
  /** 「需要提前准备」开关 */
  @State needPrep: boolean = false;
  /** 从哪天开始准备（0 点时间戳）：开关打开时才有意义 */
  @State prepDate: number = 0;
  /** 内容为空还点保存时亮红字提示，而不是静默无反应 */
  @State textError: boolean = false;
  /** 开关开着但日期被清成「无日期」时亮红字：长期任务必须有截止日才有横条可画 */
  @State dateError: boolean = false;
  /** 截止时刻的「时」；-1 = 不设截止时刻（无日期时必然是这个值） */
  @State dueHour: number = -1;
  /** 截止时刻的「分」；dueHour 为 -1 时这个值没意义 */
  @State dueMinute: number = 0;

  aboutToAppear(): void {
    this.text = this.initialText;
    this.date = this.initialDate;
    this.needPrep = this.initialNeedPrep;
    // 新建时「长期任务没填开始日就默认今天」在这里落地：打开弹窗即预填今天，
    // 用户不动这一行，保存出去的开始日就是今天。
    // 编辑时必须用原来的开始日——落回今天等于把开始日偷偷改掉了。
    this.prepDate = this.initialPrepDate > 0 ? this.initialPrepDate : startOfDay(Date.now());
    // 编辑已有条目时把截止时刻拆成时 / 分回填；0 表示本来就没设，
    // 保持 dueHour 为 -1（不设），免得把「没设」显示成「00:00」
    if (this.initialDueTime > 0) {
      const d: Date = new Date(this.initialDueTime);
      this.dueHour = d.getHours();
      this.dueMinute = d.getMinutes();
    }
  }

  /** 校验 + 回调。校验不过不关弹窗、不回调，红字提示留在原地让用户补 */
  private confirm(): void {
    const trimmed: string = this.text.trim();
    if (trimmed.length === 0) {
      this.textError = true;
      return;
    }
    // 开关开着 = 长期任务：甘特横条从开始日画到截止日，没有截止日的横条画不出来，
    // 这条数据也会在「近期」和甘特里双双隐形，所以必须拦下来补齐
    if (this.needPrep && this.date === null) {
      this.dateError = true;
      return;
    }
    // 截止时刻在这里才组装成绝对时间戳：库里 date 存的是当天 0 点，
    // 加上时分偏移就是当天那个时刻。存「时 / 分」而不是存时间戳的好处是
    // 用户改完日期不用额外处理，这次组装自然带上新日期。
    let due: number | null = null;
    if (this.date !== null && this.dueHour >= 0) {
      due = this.date + (this.dueHour * 60 + this.dueMinute) * 60 * 1000;
    }
    this.onConfirm(trimmed, this.date, this.needPrep ? this.prepDate : null, due);
  }

  /**
   * 弹系统日期选择器。日期行和「从哪天开始准备」行都要弹，只差「确定后交给谁」，
   * 把回调参数化成一个方法，省得两处各复制一份选择器配置。
   */
  private pickDate(current: number, onPicked: (dayStart: number) => void): void {
    this.getUIContext().showDatePickerDialog({
      start: new Date(2000, 0, 1),
      end: new Date(2100, 11, 31),
      selected: new Date(current),
      onDateAccept: (value: Date) => {
        // 选择器回传的 Date 带着系统时间的时分秒，必须归一化回 0 点，
        // 和库里「日期一律存 0 点」的约定保持一致
        onPicked(startOfDay(value.getTime()));
      }
    });
  }

  /**
   * 弹系统时间选择器选截止时刻。和 pickDate 分成两个方法：
   * 时间选择器的入参（selected 用带时分的 Date）、回传类型（TimePickerResult）都不一样，
   * 硬凑成一个反而要写类型分支，不如各写各的。
   */
  private pickTime(): void {
    // 初值：设过就停在那上面；没设过用此刻的时分——写死某个钟点（比如 18:00）
    // 反而容易让人没注意就存下一个不是自己想要的时刻
    const base: Date = this.dueHour >= 0
      ? new Date(2000, 0, 1, this.dueHour, this.dueMinute)
      : new Date();
    this.getUIContext().showTimePickerDialog({
      selected: base,
      format: TimePickerFormat.HOUR_MINUTE,
      // 24 小时制：国内习惯，也和课表条目显示的「08:00」一个路子
      useMilitaryTime: true,
      onAccept: (value: TimePickerResult) => {
        this.dueHour = value.hour;
        this.dueMinute = value.minute;
      }
    });
  }

  /**
   * 截止时刻行右侧文案：设过显示「18:00」，没设给一句灰字占位。
   * 用 this.dueHour < 0 判「没设」，而不是拿 dueMinute 一起判：
   * 用户完全可能选 00:00 当截止时刻，那是个合法值，不能当成「没设」。
   */
  private dueText(): string {
    if (this.dueHour < 0) {
      return '不设截止时刻';
    }
    return `${pad2(this.dueHour)}:${pad2(this.dueMinute)}`;
  }

  /** 日期行右侧文案：「2026年9月30日」；无日期时给一句灰字占位 */
  private dateText(): string {
    if (this.date === null) {
      return '无日期';
    }
    const d: Date = new Date(this.date);
    return `${d.getFullYear()}年${d.getMonth() + 1}月${d.getDate()}日`;
  }

  /** 「从哪天开始准备」行右侧文案，格式同日期行（这一行永远有值，不需要占位） */
  private prepDateText(): string {
    const d: Date = new Date(this.prepDate);
    return `${d.getFullYear()}年${d.getMonth() + 1}月${d.getDate()}日`;
  }

  build() {
    Column() {
      Text(this.isEdit ? '改一条' : '记一条')
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .margin({ bottom: 14 })

      // 内容（唯一必填项）
      Column({ space: 6 }) {
        // text 必须回传：aboutToAppear 已经把原文存进 this.text，这里不绑的话
        // 输入框只显示 placeholder，点「改一条」看不到原文——用户会以为内容丢了，
        // 直接保存则把原文原样写回（看着像没生效），随手输入又会整段覆盖
        TextInput({ text: this.text, placeholder: '写点什么' })
          .onChange((value: string) => {
            this.text = value;
            this.textError = false;
          })
          .width('100%')
        if (this.textError) {
          Text('内容不能为空')
            .fontSize(11)
            .fontColor($r('app.color.danger'))
        }
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')

      // 日期行：点整行弹系统日期选择器改日期；「清除」把日期退回「无日期」
      Row() {
        Text('日期')
          .fontSize(14)
          .fontColor($r('app.color.text_primary'))
        Blank()
        Text(this.dateText())
          .fontSize(14)
          .fontColor(this.date === null ? $r('app.color.text_secondary') : $r('app.color.text_primary'))
        if (this.date !== null) {
          // 内层自带 onClick，点击会先被它接住，不会连带触发整行的日期选择器
          Text('清除')
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .padding({ left: 8, top: 4, bottom: 4 })
            .onClick(() => {
              this.date = null;
              // 截止时刻依附于日期，日期没了它也无从谈起；
              // 一并清掉，免得留下一个下次进来会突然冒出来的悬空时刻
              this.dueHour = -1;
            })
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .padding({ top: 12, bottom: 12 })
      .onClick(() => {
        // 当前是「无日期」也要能弹选择器：从今天开始选，而不是从 2000 年开始滑
        const base: number = this.date !== null ? this.date : startOfDay(Date.now());
        this.pickDate(base, (dayStart: number): void => {
          this.date = dayStart;
          this.dateError = false;
        });
      })

      // 截止时刻行：只在有日期时出现——它依附于日期，无日期的随手记不设截止。
      // 交互和日期行完全一致：点整行弹选择器、「清除」退回不设
      if (this.date !== null) {
        Row() {
          Text('截止时刻')
            .fontSize(14)
            .fontColor($r('app.color.text_primary'))
          Blank()
          Text(this.dueText())
            .fontSize(14)
            .fontColor(this.dueHour < 0 ? $r('app.color.text_secondary') : $r('app.color.text_primary'))
          if (this.dueHour >= 0) {
            Text('清除')
              .fontSize(12)
              .fontColor($r('app.color.text_secondary'))
              .padding({ left: 8, top: 4, bottom: 4 })
              .onClick(() => {
                this.dueHour = -1;
              })
          }
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .padding({ top: 12, bottom: 12 })
        .onClick(() => {
          this.pickTime();
        })
      }

      // 开关：让用户显式选一次「单日事项还是长期任务」，
      // 理由见文件头——单靠开始日填没填在数据上区分不出两者
      Row() {
        Text('需要提前准备')
          .fontSize(14)
          .fontColor($r('app.color.text_primary'))
        Blank()
        Toggle({ type: ToggleType.Switch, isOn: this.needPrep })
          .onChange((isOn: boolean) => {
            this.needPrep = isOn;
            // 开关一关，长期任务才需要的「截止日期」校验自然失效
            if (!isOn) {
              this.dateError = false;
            }
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      // 开关打开时多出的一行：从哪天开始准备，默认今天，点行可改
      if (this.needPrep) {
        Row() {
          Text('从哪天开始准备')
            .fontSize(14)
            .fontColor($r('app.color.text_primary'))
          Blank()
          Text(this.prepDateText())
            .fontSize(14)
            .fontColor($r('app.color.text_primary'))
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .padding({ top: 12, bottom: 12 })
        .onClick(() => {
          this.pickDate(this.prepDate, (dayStart: number): void => {
            this.prepDate = dayStart;
          });
        })
      }

      // 长期任务的截止日校验提示：亮红字但不关弹窗，补上日期就能保存
      if (this.dateError) {
        Column() {
          Text('长期任务需要一个截止日期')
            .fontSize(11)
            .fontColor($r('app.color.danger'))
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%')
      }

      // 按钮区：样式沿用课表录入弹窗——灰底取消 + 深底保存；编辑时最左多一个红字删除
      Row({ space: 12 }) {
        if (this.isEdit) {
          Button('删除')
            .layoutWeight(1)
            .backgroundColor($r('app.color.bg_subtle'))
            .fontColor($r('app.color.danger'))
            .onClick(() => {
              this.onDelete();
            })
        }
        Button('取消')
          .layoutWeight(1)
          .backgroundColor($r('app.color.bg_subtle'))
          .fontColor($r('app.color.text_body'))
          .onClick(() => {
            this.onCancel();
          })
        Button('保存')
          .layoutWeight(1)
          .backgroundColor($r('app.color.button_primary_bg'))
          .onClick(() => {
            this.confirm();
          })
      }
      .width('100%')
      .margin({ top: 16 })
    }
    .padding(20)
    .width('88%')
    .borderRadius(16)
    .backgroundColor($r('app.color.bg_card'))
  }
}

/** 两位补零，拼时间文案用。和 EntryDisplay 里那个同名函数各自持有一份：
 *  各文件自带一个几行的小工具是这个项目既有的取舍（见 DailyRollover 的 startOfDay） */
function pad2(n: number): string {
  return n < 10 ? `0${n}` : `${n}`;
}
