/**
 * 文件路径：entry/src/main/ets/data/DbHelper.ets
 * 用途：本地 relationalStore 数据库的单例封装。
 *       建四张表：entry / timetable / timetable_exception / settings，列名与 Types.ets 字段一一对应；
 *       覆盖三类读写：条目（增查改 + 软删）、课表（规则与例外）、设置（键值对）。
 */

import { relationalStore } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { BusinessError, emitter } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { EntryItem, EntrySource, TimetableRule, TimetableException, WeekRepeatMode, ExceptionType, SettingsKey, RuntimeKey } from './Types';

/**
 * 「端云同步跑完了一轮」的广播事件 id。界面订阅它，一收到就重读数据库。
 *
 * 为什么非要有这个广播：同步是后台悄悄干的，它把云上的数据写进本地库时，
 * 界面正开着的那一屏并不知道库变了。实测（2026-09-28）就是这么个结果 ——
 * 把 App 卸载重装、云端数据确实拉回来了（辅助日志里 device='cloud'），
 * 可主页还停在「还没有内容」上，非要把 App 杀掉重开才看得见。
 * 手机上记一条、平板上得重启才出现，同步等于白做。
 *
 * 事件 id 取 1001 是因为 emitter 只认数字，系统不占用这些小整数。
 */
export const SYNC_DONE_EVENT: number = 1001;

/** 数据库封装单例：建表 + 条目 / 课表 / 设置的读写 */
export class DbHelper {
  /** 全局唯一实例 */
  private static instance: DbHelper | undefined = undefined;
  /** 数据库对象，初始化完成后一直有效 */
  private store: relationalStore.RdbStore | undefined = undefined;
  /** 进行中的初始化任务，防止并发首次调用时重复建库 */
  private initing: Promise<void> | undefined = undefined;

  /** 私有构造，外部只能通过 getInstance 获取单例 */
  private constructor() {
  }

  /**
   * 获取 DbHelper 单例。首次调用会创建数据库并建好四张表；之后调用直接复用。
   * @param context 应用上下文（在 Ability 里传 this 即可）
   * @returns 初始化完成的单例
   */
  static async getInstance(context: common.Context): Promise<DbHelper> {
    if (DbHelper.instance === undefined) {
      DbHelper.instance = new DbHelper();
    }
    await DbHelper.instance.ensureInit(context);
    return DbHelper.instance;
  }

  /**
   * 插入一条条目。id 由调用方生成（uuid），主键冲突会抛错。
   * @param item 完整条目
   * @returns 是否插入成功
   */
  async insertEntry(item: EntryItem): Promise<boolean> {
    const store = this.getStore();
    const values: relationalStore.ValuesBucket = {
      'id': item.id,
      'title': item.title,
      'body': item.body,
      'date': item.date,
      'dueTime': item.dueTime,
      'startDate': item.startDate,
      'done': item.done,
      'doneAt': item.doneAt,
      'source': item.source,
      'sourceRef': item.sourceRef,
      'sortOrder': item.sortOrder,
      'ganttOrder': item.ganttOrder,
      'deleted': item.deleted,
      'createdAt': item.createdAt,
      'updatedAt': item.updatedAt
    };
    const rowId = await store.insert('entry', values);
    return rowId >= 0;
  }

  /**
   * 按 id 查一条条目（含已软删除的，回收站场景由调用方看 deleted 字段）。
   * @param id 条目 uuid
   * @returns 查到返回条目，查不到返回 undefined
   */
  async getEntryById(id: string): Promise<EntryItem | undefined> {
    const predicates = new relationalStore.RdbPredicates('entry');
    predicates.equalTo('id', id);
    const list = await this.queryEntries(predicates);
    if (list.length > 0) {
      return list[0];
    }
    return undefined;
  }

  /**
   * 查某一天的全部条目（只含未删除的），按 sortOrder 升序、createdAt 升序排。
   * @param date 当天 0 点的毫秒时间戳
   * @returns 条目列表，没有则为空数组
   */
  async getEntriesByDate(date: number): Promise<EntryItem[]> {
    const predicates = new relationalStore.RdbPredicates('entry');
    predicates.equalTo('date', date)
      .equalTo('deleted', 0)
      .orderByAsc('sortOrder')
      .orderByAsc('createdAt');
    return await this.queryEntries(predicates);
  }

  /**
   * 查全部未删除的条目（含已勾掉的）。主页一屏取数只发这一条查询，
   * 「近期 / 随手记 / 甘特」三块各自在内存里过滤分组，避免多次往返数据库。
   * @returns 条目列表，没有则为空数组
   */
  async getAllActiveEntries(): Promise<EntryItem[]> {
    const predicates = new relationalStore.RdbPredicates('entry');
    predicates.equalTo('deleted', 0)
      .orderByAsc('sortOrder')
      .orderByAsc('createdAt');
    return await this.queryEntries(predicates);
  }

  /**
   * 更新一条条目（按 id 匹配，除 id / createdAt 外全量覆盖，updatedAt 以 item 里带的值为准）。
   * @param item 改好的完整条目
   * @returns 是否真的更新到了行（id 不存在则 false）
   */
  async updateEntry(item: EntryItem): Promise<boolean> {
    const store = this.getStore();
    const values: relationalStore.ValuesBucket = {
      'title': item.title,
      'body': item.body,
      'date': item.date,
      'dueTime': item.dueTime,
      'startDate': item.startDate,
      'done': item.done,
      'doneAt': item.doneAt,
      'source': item.source,
      'sourceRef': item.sourceRef,
      'sortOrder': item.sortOrder,
      'ganttOrder': item.ganttOrder,
      'deleted': item.deleted,
      'updatedAt': item.updatedAt
    };
    const predicates = new relationalStore.RdbPredicates('entry');
    predicates.equalTo('id', item.id);
    const rows = await store.update(values, predicates);
    return rows > 0;
  }

  /**
   * 软删除一条条目（只打 deleted 标记并刷新 updatedAt，物理上不删行，回收站靠它）。
   * @param id 条目 uuid
   * @returns 是否真的删到了行（id 不存在则 false）
   */
  async softDeleteEntry(id: string): Promise<boolean> {
    const store = this.getStore();
    const values: relationalStore.ValuesBucket = {
      'deleted': 1,
      'updatedAt': Date.now()
    };
    const predicates = new relationalStore.RdbPredicates('entry');
    predicates.equalTo('id', id);
    const rows = await store.update(values, predicates);
    return rows > 0;
  }

  /**
   * 查全部已软删除的条目（回收站用），最近删的排最前。
   * @returns 条目列表，没有则为空数组
   */
  async getDeletedEntries(): Promise<EntryItem[]> {
    const predicates = new relationalStore.RdbPredicates('entry');
    predicates.equalTo('deleted', 1)
      .orderByDesc('updatedAt');
    return await this.queryEntries(predicates);
  }

  /**
   * 从回收站恢复：把软删标记清掉，条目重新回到主界面。
   *
   * **同时要清掉勾掉标记。** 原来只清 deleted，于是这样一条路是死的：
   * 「已完成」里点删除 → 进回收站 → 点恢复 → done 还是 1 → 主界面按 done 过滤
   * （SectionLogic 那条 `item.done` 判断）根本不放它出来，它又原样回到「已完成」，
   * 用户看到的是一按恢复就跳回原来那页，怎么点都出不来。
   * 「已完成」里的条目本来就有来路不同的两种（见 ArchivePage.refresh）：
   * 用户勾掉的（done=1）和过期满 7 天自动退场的（done=0）。清 done 只动前者，
   * 后者本来就是 0，不受影响——恢复回去仍落在「过期」段，跟删之前一样。
   * 恢复的语义就是「把这条弄回来」，对勾掉的条目而言就是把勾撤了、让它回到列表。
   * @param id 条目 uuid
   * @returns 是否真的恢复到了行（id 不存在则 false）
   */
  async restoreEntry(id: string): Promise<boolean> {
    const store = this.getStore();
    const values: relationalStore.ValuesBucket = {
      'deleted': 0,
      'done': 0,
      'doneAt': null,
      'updatedAt': Date.now()
    };
    const predicates = new relationalStore.RdbPredicates('entry');
    predicates.equalTo('id', id);
    const rows = await store.update(values, predicates);
    return rows > 0;
  }

  /**
   * 物理删除一条条目（回收站里「彻底删除」用，删了就真没了）。
   * 与软删的区别：软删只是打标记还能找回，这个是 `store.delete`，行直接从表里消失。
   * @param id 条目 uuid
   * @returns 是否真的删到了行（id 不存在则 false）
   */
  async hardDeleteEntry(id: string): Promise<boolean> {
    const store = this.getStore();
    const predicates = new relationalStore.RdbPredicates('entry');
    predicates.equalTo('id', id);
    const rows = await store.delete(predicates);
    return rows > 0;
  }

  /**
   * 物理删除已经没有意义的课表条目（不走软删、不进回收站）。
   * 为什么课表条目可以物理删：它只是「那天有这节课」的临时提示，过完就没有留存价值，
   * 走软删反而会让回收站被每天一批的过期课表塞满，把真正手写的内容淹没。
   * 删两类，但都限定 source = 'timetable'，用户手写的条目一条都不碰：
   * - date 在今天之前的：隔多天没开 App 时积压的旧课表，顺带兜住 dueTime 为 NULL 的脏数据；
   * - dueTime（上课时刻）已经过了的：用户的要求是「过了上课时间就直接删掉」，
   *   不等第二天结算，当天的课一过点就退场。
   * date / dueTime 为 NULL 的行不会被 SQL 的大小比较命中，随手记不受影响。
   * @param todayStart 今天 0 点的毫秒时间戳
   * @param now        当前毫秒时间戳
   * @returns 实际删掉的行数
   */
  async deletePassedTimetableEntries(todayStart: number, now: number): Promise<number> {
    const store = this.getStore();
    const oldPredicates = new relationalStore.RdbPredicates('entry');
    oldPredicates.equalTo('source', 'timetable')
      .lessThan('date', todayStart);
    const oldRows: number = await store.delete(oldPredicates);
    const passedPredicates = new relationalStore.RdbPredicates('entry');
    passedPredicates.equalTo('source', 'timetable')
      .lessThan('dueTime', now);
    const passedRows: number = await store.delete(passedPredicates);
    return oldRows + passedRows;
  }

  /**
    * 删掉某一天已生成的课表条目（物理删，不进回收站，理由同 deletePassedTimetableEntries）。
   * 只给「改了调休、要重算那一天」用：结算的幂等闸门按「规则 + 日期」判重，
   * 不先清掉那天旧的课，重算就会被闸门整条挡住，等于调休白设。
   * 只删 source = 'timetable' 的，用户自己写的条目一条都不碰。
   * @param dayStart 那一天 0 点的毫秒时间戳
   * @returns 删掉的行数
   */
  async deleteTimetableEntriesOfDay(dayStart: number): Promise<number> {
    const store = this.getStore();
    const predicates = new relationalStore.RdbPredicates('entry');
    predicates.equalTo('source', 'timetable')
      .equalTo('date', dayStart);
    return await store.delete(predicates);
  }

  /**
   * 查库里是否已存在「某来源 + 某引用 + 某天」的条目。
   * 每日结算在生成条目前先问它：存在就不再生成，跑十次和跑一次结果一样（幂等的关键）。
   * 注意故意不过滤 done / deleted：生成出来的条目即使被勾掉或删进回收站也算「生成过」，
   * 否则每次启动都会再生成一条，用户勾掉 / 删除的动作就白做了。
   * @param source    条目来源（timetable / longterm）
   * @param sourceRef 来源引用（课表规则 id 或长期任务原条目 id）
   * @param date      当天 0 点的毫秒时间戳
   * @returns 已存在返回 true
   */
  async hasEntryOfSource(source: EntrySource, sourceRef: string, date: number): Promise<boolean> {
    const predicates = new relationalStore.RdbPredicates('entry');
    predicates.equalTo('source', source)
      .equalTo('sourceRef', sourceRef)
      .equalTo('date', date)
      .limitAs(1);
    const resultSet = await this.getStore().query(predicates);
    try {
      return resultSet.goToNextRow();
    } finally {
      resultSet.close();
    }
  }

  /**
   * 插入一条课表规则。id 由调用方生成（uuid），主键冲突会抛错。
   * @param rule 完整课表规则
   * @returns 是否插入成功
   */
  async insertRule(rule: TimetableRule): Promise<boolean> {
    const store = this.getStore();
    const values: relationalStore.ValuesBucket = {
      'id': rule.id,
      'weekday': rule.weekday,
      'periodFrom': rule.periodFrom,
      'periodTo': rule.periodTo,
      'name': rule.name,
      'location': rule.location,
      'weeks': rule.weeks,
      'weekFrom': rule.weekFrom,
      'weekTo': rule.weekTo,
      'timeStart': rule.timeStart
    };
    const rowId = await store.insert('timetable', values);
    return rowId >= 0;
  }

  /**
   * 查全部课表规则，按星期几、第几节开始升序排，画课表网格时可直接按顺序铺。
   * @returns 规则列表，没有则为空数组
   */
  async getAllRules(): Promise<TimetableRule[]> {
    const predicates = new relationalStore.RdbPredicates('timetable');
    predicates.orderByAsc('weekday').orderByAsc('periodFrom');
    return await this.queryRules(predicates);
  }

  /**
   * 更新一条课表规则（按 id 匹配，除 id 外全量覆盖）。
   * @param rule 改好的完整规则
   * @returns 是否真的更新到了行（id 不存在则 false）
   */
  async updateRule(rule: TimetableRule): Promise<boolean> {
    const store = this.getStore();
    const values: relationalStore.ValuesBucket = {
      'weekday': rule.weekday,
      'periodFrom': rule.periodFrom,
      'periodTo': rule.periodTo,
      'name': rule.name,
      'location': rule.location,
      'weeks': rule.weeks,
      'weekFrom': rule.weekFrom,
      'weekTo': rule.weekTo,
      'timeStart': rule.timeStart
    };
    const predicates = new relationalStore.RdbPredicates('timetable');
    predicates.equalTo('id', rule.id);
    const rows = await store.update(values, predicates);
    return rows > 0;
  }

  /**
   * 物理删除一条课表规则。课表是「规则」不是「条目」，没有回收站概念，直接删行。
   * @param id 规则 uuid
   * @returns 是否真的删到了行（id 不存在则 false）
   */
  async deleteRule(id: string): Promise<boolean> {
    const store = this.getStore();
    const predicates = new relationalStore.RdbPredicates('timetable');
    predicates.equalTo('id', id);
    const rows = await store.delete(predicates);
    return rows > 0;
  }

  /**
   * 插入一条课表例外（调休）。id 由调用方生成（uuid），主键冲突会抛错。
   * @param exception 完整例外
   * @returns 是否插入成功
   */
  async insertException(exception: TimetableException): Promise<boolean> {
    const store = this.getStore();
    const values: relationalStore.ValuesBucket = {
      'id': exception.id,
      'date': exception.date,
      'type': exception.type,
      'weekday': exception.weekday
    };
    const rowId = await store.insert('timetable_exception', values);
    return rowId >= 0;
  }

  /**
   * 查某一天的课表例外（调休），一天最多一条。
   * @param date 当天 0 点的毫秒时间戳
   * @returns 查到返回例外，查不到返回 undefined
   */
  async getExceptionByDate(date: number): Promise<TimetableException | undefined> {
    const predicates = new relationalStore.RdbPredicates('timetable_exception');
    predicates.equalTo('date', date);
    const resultSet = await this.getStore().query(predicates);
    let result: TimetableException | undefined = undefined;
    try {
      if (resultSet.goToNextRow()) {
        result = this.rowToException(resultSet);
      }
    } finally {
      resultSet.close();
    }
    return result;
  }

  /**
   * 删掉某一天的课表例外。一天最多一条，所以按日期删就够，不用 id。
   * 界面改调休走「先删后插」：把某天从「不上课」改回正常，就是只删不插。
   * @param date 当天 0 点的毫秒时间戳
   * @returns 是否真的删到了行（那天本来就没设过调休时为 false）
   */
  async deleteExceptionByDate(date: number): Promise<boolean> {
    const predicates = new relationalStore.RdbPredicates('timetable_exception');
    predicates.equalTo('date', date);
    const rows = await this.getStore().delete(predicates);
    return rows > 0;
  }

  /**
   * 读一个设置项。
   * @param key 设置键。用户可见的设置见 Types.ets 的 SettingsKey，
   *            代码自己记账的状态见 RuntimeKey，两者共用这张表。
   * @returns 查到返回字符串值，查不到返回 undefined
   */
  async getSetting(key: SettingsKey | RuntimeKey): Promise<string | undefined> {
    return this.readSetting(key);
  }

  /**
   * 读一张卡片的尺寸档位（formInfo.FormDimension 枚举值转成的字符串）。
   * 为什么 key 里要带 formId：桌面可能同时放着一张 4*4 和一张 6*4，共用同一个 key 的话
   * 后写的那张会把前一张覆盖掉，窄卡片就会按宽档渲染、文字撑破版面。
   * 为什么不把这个 key 放进 Types.ets 的 RuntimeKey：那是个固定的字面量联合类型，
   * 没法为每个 formId 预先列一个成员，所以单开这两个方法走同一张 settings 表。
   * @param formId 卡片实例 id（onAddForm / onUpdateForm 回调里给的那个）
   */
  async getFormDimension(formId: string): Promise<string | undefined> {
    return this.readSetting(`formDimension:${formId}`);
  }

  /** 写一张卡片的尺寸档位，见 getFormDimension 的说明 */
  async setFormDimension(formId: string, value: string): Promise<boolean> {
    return this.writeSetting(`formDimension:${formId}`, value);
  }

  /**
   * 删掉一张卡片的尺寸记录。卡片从桌面移除时调用——不删的话，每「加一张卡、
   * 再把它删掉」都会在 settings 表里留下一行永久记录，加删几次就攒几行，只增不减。
   * 删不到也算成功（本来就没有这行，目的已达成）。
   * @param formId 卡片实例 id
   */
  async deleteFormDimension(formId: string): Promise<boolean> {
    const predicates = new relationalStore.RdbPredicates('settings');
    predicates.equalTo('key', `formDimension:${formId}`);
    const rows = await this.getStore().delete(predicates);
    return rows >= 0;
  }

  /**
   * 读一个设置项的共用实现。
   * @param key 设置键。用户可见的设置见 Types.ets 的 SettingsKey，代码自己记账的状态见
   *            RuntimeKey，卡片尺寸是每个 formId 一条（见 getFormDimension），三者共用这张表
   * @returns 查到返回字符串值，查不到返回 undefined
   */
  private async readSetting(key: string): Promise<string | undefined> {
    const predicates = new relationalStore.RdbPredicates('settings');
    predicates.equalTo('key', key);
    const resultSet = await this.getStore().query(predicates);
    let value: string | undefined = undefined;
    try {
      if (resultSet.goToNextRow()) {
        value = resultSet.getString(resultSet.getColumnIndex('value'));
      }
    } finally {
      resultSet.close();
    }
    return value;
  }

  /**
   * 写一个设置项（键值对，键已存在则整行覆盖，天然是「存在即更新」语义）。
   * @param key 设置键（SettingsKey 或 RuntimeKey，见 Types.ets）
   * @param value 设置值（统一按字符串存，读出来再转对应类型）
   * @returns 是否写入成功
   */
  async setSetting(key: SettingsKey | RuntimeKey, value: string): Promise<boolean> {
    return this.writeSetting(key, value);
  }

  /** 写一个设置项的共用实现，键的说明见 setSetting */
  private async writeSetting(key: string, value: string): Promise<boolean> {
    const store = this.getStore();
    const values: relationalStore.ValuesBucket = {
      'key': key,
      'value': value
    };
    const rowId = await store.insert('settings', values, relationalStore.ConflictResolution.ON_CONFLICT_REPLACE);
    return rowId >= 0;
  }

  /** 确保数据库只初始化一次；并发调用共用同一个初始化任务，失败后允许下次重试 */
  private async ensureInit(context: common.Context): Promise<void> {
    if (this.store !== undefined) {
      return;
    }
    if (this.initing === undefined) {
      this.initing = this.initStore(context).catch((e: BusinessError): void => {
        this.initing = undefined;
        throw new Error(`数据库初始化失败: ${e.message}`);
      });
    }
    await this.initing;
  }

  /** 打开（或创建）数据库并建四张表 */
  private async initStore(context: common.Context): Promise<void> {
    const config: relationalStore.StoreConfig = {
      name: 'memo.db',
      securityLevel: relationalStore.SecurityLevel.S1
    };
    const store = await relationalStore.getRdbStore(context, config);
    await this.createTables(store);
    await this.ensureColumns(store);
    // 必须排在登记同步之前：登记的时候系统就按当前本地表结构去比对云侧 schema 了，
    // 带着 NOT NULL 去登记，登记下来的就是一份对不上的结构。
    await this.dropExtraNotNull(store);
    await this.enableCloudSync(store);
    this.store = store;
  }

  /**
   * 给老库补上后来新增的列。建表用的是 CREATE TABLE IF NOT EXISTS，
   * 表已存在就整条跳过 —— 新列不会自己出现，所以每次启动都要检查一遍，缺了就补。
   * 目前要补的是 entry.ganttOrder。
   */
  private async ensureColumns(store: relationalStore.RdbStore): Promise<void> {
    try {
      await this.addColumnIfMissing(store, 'entry', 'ganttOrder', 'INTEGER');
    } catch (e) {
      // 补列失败绝不能把整个数据库初始化带崩：真失败了，最坏结果是甘特顺序存不住
      // （拖完重启就回去了），但列表、卡片、其它功能都还能正常用。
      // 这里吞掉异常、只留一条日志 —— 排查时按这行日志找。
      hilog.error(0x0000, 'DbHelper', `补列失败: ${JSON.stringify(e)}`);
    }
  }

  /**
   * 把三张业务表登记成「端云同步表」，数据就会跟着用户的华为账号在设备之间跑。
   * 只登记 entry（条目）、timetable（课表规则）、timetable_exception（调休）三张，
   * 故意不登记 settings：那张表里混着每台设备各不相同的东西 ——
   * 「每日结算跑到哪天」这类代码自己的记账（同步过去会让另一台设备跳过它自己的结算），
   * 以及每张桌面卡片的尺寸记录（键里带卡片 id，两台设备的卡片 id 不一样，同步会互相覆盖）。
   *
   * 登记完还要主动推一次。别指望 autoSync：它只是说「系统可以自己找时机同步」，
   * 而实测（2026-09-27）光等系统是不够的 —— 平板上写进去的数据一直没上云，
   * 辅助变更日志里 cloud_gid 始终为空，系统日志里是「get cloud table err[-1075]」，
   * 端侧连云侧的表结构都没拿到过。主动调一次 cloudSync 既能直接推数据，
   * 失败时还会把错误码交出来，出了事有据可查；干等系统的话，出问题只能看系统日志猜。
   *
   * 为什么整个包在 try/catch 里：登记失败绝不能把数据库初始化带崩。
   * 云侧还没配好、设备没登录华为账号、系统版本不够，都会让这一步失败；
   * 真失败了最坏结果是「同步不生效」，本地增删改查、卡片、课表都照常能用。
   * 跟 ensureColumns 的兜底是一个道理，这里同样只留一条日志。
   */
  private async enableCloudSync(store: relationalStore.RdbStore): Promise<void> {
    const tables: string[] = ['entry', 'timetable', 'timetable_exception'];
    try {
      await store.setDistributedTables(
        tables,
        relationalStore.DistributedType.DISTRIBUTED_CLOUD,
        { autoSync: true }
      );
    } catch (e) {
      hilog.error(0x0000, 'DbHelper', `端云同步登记失败: ${JSON.stringify(e)}`);
      // 登记都没成，同步必然不成，不用白试一次
      return;
    }
    // 故意不 await：同步要联网，慢起来好几秒，卡在这儿等于让 App 启动干等。
    // 推到哪一步、成没成，回调里都写着，日志里看得见。
    // 模式选「以最新修改时间为准」：两台设备都改了同一条时，留最近改的那份。
    //
    // 为什么下面还要再包一层 try：末尾的 .catch() 只管「Promise 被拒绝」这一种情况。
    // 万一 cloudSync 当场就抛（参数不对、系统版本不够），那是在返回 Promise 之前抛的，
    // .catch() 接不住，会顺着 initStore 往上炸 —— 跟登记失败一个下场。
    //
    // 日志为什么连 message 一起打：出问题时 code 只是个数字，
    // 真正说得清原因的是 message（实测 code=3 对应「云端不可用」，
    // 但到底是没登录、没配置还是没联网，全在 message 里）。
    try {
      store.cloudSync(
        relationalStore.SyncMode.SYNC_MODE_TIME_FIRST,
        tables,
        (details: relationalStore.ProgressDetails): void => {
          hilog.info(0x0000, 'DbHelper',
            `端云同步 schedule=${details.schedule} code=${details.code} ` +
            `message=${details.message ?? '-'} detail=${JSON.stringify(details.details)}`);
          // 这一轮同步收尾了、而且是成功的：库里此刻可能刚被写进云上下来的数据，
          // 广播一声让开着的界面重读。不广播的话主页还停在旧的一屏上，
          // 用户只会以为「没同步过来」。
          //
          // 条件卡两道：schedule 到 SYNC_FINISH 才算跑完（中途那些进度广播了也没用，
          // 数据还没落库），code 是 SUCCESS 才算真成了（失败时广播等于让界面白读一次）。
          if (details.schedule === relationalStore.Progress.SYNC_FINISH &&
            details.code === relationalStore.ProgressCode.SUCCESS) {
            emitter.emit({ eventId: SYNC_DONE_EVENT });
          }
        }
      ).catch((e: BusinessError): void => {
        hilog.error(0x0000, 'DbHelper', `主动端云同步失败: ${JSON.stringify(e)}`);
      });
    } catch (e) {
      hilog.error(0x0000, 'DbHelper', `主动端云同步调用失败: ${JSON.stringify(e)}`);
    }
  }

  /**
   * 某一列不在表里就 ALTER TABLE 加上。SQLite 的 ADD COLUMN 是原地加一列，
   * 不重建表、不动已有数据；老行的新列值是 NULL，正好就是 ganttOrder 想要的「还没拖过」。
   *
   * 怎么判断列在不在：查一行（LIMIT 1）拿结果集的列名，看这一列在不在里面。
   * 用 ResultSet 自带的 getColumnNames，不写 PRAGMA —— pragma_table_info 是 SQLite 的
   * 表值函数，能不能用要看底层版本；getColumnNames 是 ResultSet 自己的接口，一定有。
   * LIMIT 1 只是别把整表捞上来，列信息在查询准备阶段就定了，表里一行数据都没有也照样有列名。
   */
  private async addColumnIfMissing(
    store: relationalStore.RdbStore,
    table: string,
    column: string,
    type: string
  ): Promise<void> {
    const rs = await store.querySql(`SELECT * FROM ${table} LIMIT 1`);
    const names: string[] = rs.getColumnNames();
    rs.close();
    let has: boolean = false;
    for (const n of names) {
      if (n === column) {
        has = true;
      }
    }
    if (!has) {
      await store.executeSql(`ALTER TABLE ${table} ADD COLUMN ${column} ${type}`);
    }
  }

  /**
   * 三张「端云同步表」的列定义，建表和重建表都从这儿取。
   *
   * 为什么抽出来共用：老库迁移时也得照这份定义重建（见 dropExtraNotNull），
   * 两处各写一份的话，将来改了建表忘了改重建，就会出现「新装的对、老库迁移完还是错的」，
   * 而且这种错只在老设备上出现，最难发现。
   *
   * 列的顺序按 Types.ets 里的字段顺序排列；但重建老表时**不能**依赖它，
   * 必须配合 syncColumnNames 按列名搬数据，原因见那个方法的注释。
   *
   * 所有列都不写 NOT NULL —— 这是端云同步的硬要求，理由见 dropExtraNotNull。
   */
  private syncColumns(table: string): string {
    if (table === 'entry') {
      return `id TEXT PRIMARY KEY,
        title TEXT,
        body TEXT,
        date INTEGER,
        dueTime INTEGER,
        startDate INTEGER,
        done INTEGER,
        doneAt INTEGER,
        source TEXT,
        sourceRef TEXT,
        sortOrder INTEGER,
        ganttOrder INTEGER,
        deleted INTEGER,
        createdAt INTEGER,
        updatedAt INTEGER`;
    }
    if (table === 'timetable') {
      return `id TEXT PRIMARY KEY,
        weekday INTEGER,
        periodFrom INTEGER,
        periodTo INTEGER,
        name TEXT,
        location TEXT,
        weeks TEXT,
        weekFrom INTEGER,
        weekTo INTEGER,
        timeStart TEXT`;
    }
    return `id TEXT PRIMARY KEY,
      date INTEGER,
      type TEXT,
      weekday INTEGER`;
  }

  /**
   * 三张同步表的列名，顺序与 syncColumns 里的定义一一对应。
   *
   * 为什么单独列一份：重建老表时绝不能写 INSERT INTO ... SELECT *。
   * 老库的 ganttOrder 是后来用 ALTER TABLE 补上去的，SQLite 只能把新列追加在表尾，
   * 于是老表的物理列序是 (..., deleted, createdAt, updatedAt, ganttOrder)，
   * 而新表按 syncColumns 建出来是 (..., ganttOrder, deleted, createdAt, updatedAt)。
   * 两边都是 15 列，SELECT * 不报任何错，却会整列错位搬过去 ——
   * deleted 收到老 createdAt 的时间戳（非 0 = 已删），整张表的记事在主页上集体消失、
   * 全跑进回收站，而且看起来「迁移成功了」。
   * 所以两边都按列名对应，物理顺序不一样也没关系。
   */
  private syncColumnNames(table: string): string[] {
    if (table === 'entry') {
      return ['id', 'title', 'body', 'date', 'dueTime', 'startDate', 'done', 'doneAt',
        'source', 'sourceRef', 'sortOrder', 'ganttOrder', 'deleted', 'createdAt', 'updatedAt'];
    }
    if (table === 'timetable') {
      return ['id', 'weekday', 'periodFrom', 'periodTo', 'name', 'location', 'weeks',
        'weekFrom', 'weekTo', 'timeStart'];
    }
    return ['id', 'date', 'type', 'weekday'];
  }

  /**
   * 去掉三张同步表里多余的 NOT NULL。
   *
   * 为什么非去不可：端云同步启动时要拿本地表结构和云侧 schema 逐列比对，
   * 本地写了 NOT NULL、云侧那一列却是可空的，就直接判定 schema 不匹配、放弃这张表。
   * 实测（2026-09-28）系统日志原话是
   * "The nullable property is mismatched between local and cloud schema, column = body"，
   * 紧接着 "Get schema by tableName entry failed" —— 三张表一起废掉，一条数据都上不了云。
   * 云侧那份是 AGC 后台配出来的，字段全是可空，后台界面上压根没有「可空」这个开关、
   * 改不了，所以只能本地让步。官方《端云数据同步关系型数据库端侧开发指导》也写着
   * 「NOT NULL 约束无需添加」，照着做就对了。
   *
   * 新库由 createTables 直接建出来，天生没有 NOT NULL，走到这儿会很快跳过；
   * 老库才是真要重建的那批。settings 表不参与同步，不碰它。
   */
  private async dropExtraNotNull(store: relationalStore.RdbStore): Promise<void> {
    const tables: string[] = ['entry', 'timetable', 'timetable_exception'];
    for (const table of tables) {
      try {
        if (!(await this.hasExtraNotNull(store, table))) {
          continue;
        }
        await this.rebuildWithoutNotNull(store, table);
        hilog.info(0x0000, 'DbHelper', `已去掉 ${table} 的多余 NOT NULL`);
      } catch (e) {
        // 跟补列一样，这一步失败也不能把数据库初始化带崩：
        // 最坏结果是同步继续不生效，本地增删改查照常。
        hilog.error(0x0000, 'DbHelper', `去掉 ${table} 的 NOT NULL 失败: ${JSON.stringify(e)}`);
      }
    }
  }

  /**
   * 表里还有没有多余的 NOT NULL。
   *
   * 怎么看：直接查 sqlite_master 里那张表的建表原文，看有没有 NOT NULL 字样。
   * 不去读 PRAGMA table_info —— pragma 系列在这个接口上不是处处可用（补列那儿已经绕开一次了），
   * 而 sqlite_master 就是一张普通系统表，一定查得到。
   * 主键 id 是 TEXT PRIMARY KEY，SQLite 对这种主键不隐含 NOT NULL，原文里本来就没这几个字，
   * 所以不会误判。
   */
  private async hasExtraNotNull(store: relationalStore.RdbStore, table: string): Promise<boolean> {
    const rs = await store.querySql(
      `SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?`, [table]);
    try {
      if (!rs.goToNextRow()) {
        // 表不存在。createTables 已经跑过了，正常走不到这儿
        return false;
      }
      return rs.getString(0).includes('NOT NULL');
    } finally {
      rs.close();
    }
  }

  /**
   * 按 SQLite 官方的老规矩重建一张表：建新表 → 拷数据 → 删旧表 → 换名。
   * SQLite 不支持直接改列约束，想去掉 NOT NULL 只有这一条路。
   *
   * 整个过程包在一个事务里：哪一步失败都整体回滚，旧表原封不动，
   * 绝不会留下「旧表删了、新表没建成」这种数据全丢的中间态。
   * 索引跟着表走，DROP TABLE 时一并没了，所以换完名要重新建。
   */
  private async rebuildWithoutNotNull(store: relationalStore.RdbStore, table: string): Promise<void> {
    const tmp = `${table}_migrate`;
    store.beginTransaction();
    try {
      await store.executeSql(`DROP TABLE IF EXISTS ${tmp}`);
      await store.executeSql(`CREATE TABLE ${tmp} (${this.syncColumns(table)})`);
      // 两边都写全列名，绝不用 SELECT *：老表的物理列序可能和新表不一样
      // （ganttOrder 是后来 ALTER TABLE 补的，排在表尾），见 syncColumnNames 的注释。
      // 万一老表缺某一列，这条 SQL 会当场报「no such column」——
      // 这是好事：报错回滚，表原封不动，总比闷声错位强。
      const cols = this.syncColumnNames(table).join(', ');
      await store.executeSql(`INSERT INTO ${tmp} (${cols}) SELECT ${cols} FROM ${table}`);
      await store.executeSql(`DROP TABLE ${table}`);
      await store.executeSql(`ALTER TABLE ${tmp} RENAME TO ${table}`);
      if (table === 'entry') {
        await store.executeSql(`CREATE INDEX IF NOT EXISTS idx_entry_date_deleted ON entry (date, deleted)`);
      }
      store.commit();
    } catch (e) {
      try {
        store.rollBack();
      } catch (rollBackErr) {
        // 磁盘满、IO 这类致命错误下，SQLite 可能已经自己回滚过了，
        // 这时再 rollBack 会因「没有活跃事务」报错。不能让它把上面真正的错误盖掉，
        // 所以单独接住、只记一笔。
        hilog.error(0x0000, 'DbHelper', `回滚 ${table} 失败: ${JSON.stringify(rollBackErr)}`);
      }
      // ArkTS 只让抛 Error 类型（arkts-limited-throw），catch 到的 e 是任意类型，
      // 不能直接 throw e，得裹一层把原始信息带上 —— 不然排查时只知道「失败了」，
      // 不知道底下到底是哪条 SQL 出的问题。
      throw new Error(`重建 ${table} 失败: ${JSON.stringify(e)}`);
    }
  }

  /** 建四张表：entry / timetable / timetable_exception / settings，列名与 Types.ets 字段一一对应 */
  private async createTables(store: relationalStore.RdbStore): Promise<void> {
    await store.executeSql(`CREATE TABLE IF NOT EXISTS entry (${this.syncColumns('entry')})`);
    await store.executeSql(`CREATE INDEX IF NOT EXISTS idx_entry_date_deleted ON entry (date, deleted)`);
    await store.executeSql(`CREATE TABLE IF NOT EXISTS timetable (${this.syncColumns('timetable')})`);
    await store.executeSql(`CREATE TABLE IF NOT EXISTS timetable_exception (${this.syncColumns('timetable_exception')})`);
    await store.executeSql(`CREATE TABLE IF NOT EXISTS settings (
      key TEXT PRIMARY KEY,
      value TEXT NOT NULL
    )`);
  }

  /** 拿已初始化的数据库对象，没初始化就抛错兜底 */
  private getStore(): relationalStore.RdbStore {
    if (this.store === undefined) {
      throw new Error('数据库尚未初始化，请先调用 DbHelper.getInstance');
    }
    return this.store;
  }

  /** 按条件查条目并逐行映射，查完关闭结果集 */
  private async queryEntries(predicates: relationalStore.RdbPredicates): Promise<EntryItem[]> {
    const store = this.getStore();
    const resultSet = await store.query(predicates);
    const list: EntryItem[] = [];
    try {
      while (resultSet.goToNextRow()) {
        list.push(this.rowToEntry(resultSet));
      }
    } finally {
      resultSet.close();
    }
    return list;
  }

  /** 一行结果集 → EntryItem，可空列先判 isColumnNull 再取值 */
  private rowToEntry(resultSet: relationalStore.ResultSet): EntryItem {
    const dateIdx = resultSet.getColumnIndex('date');
    const dueTimeIdx = resultSet.getColumnIndex('dueTime');
    const startDateIdx = resultSet.getColumnIndex('startDate');
    const doneAtIdx = resultSet.getColumnIndex('doneAt');
    const sourceRefIdx = resultSet.getColumnIndex('sourceRef');
    const ganttOrderIdx = resultSet.getColumnIndex('ganttOrder');
    const item: EntryItem = {
      id: resultSet.getString(resultSet.getColumnIndex('id')),
      title: resultSet.getString(resultSet.getColumnIndex('title')),
      body: resultSet.getString(resultSet.getColumnIndex('body')),
      date: resultSet.isColumnNull(dateIdx) ? null : resultSet.getLong(dateIdx),
      dueTime: resultSet.isColumnNull(dueTimeIdx) ? null : resultSet.getLong(dueTimeIdx),
      startDate: resultSet.isColumnNull(startDateIdx) ? null : resultSet.getLong(startDateIdx),
      done: resultSet.getLong(resultSet.getColumnIndex('done')) === 1,
      doneAt: resultSet.isColumnNull(doneAtIdx) ? null : resultSet.getLong(doneAtIdx),
      source: this.toEntrySource(resultSet.getString(resultSet.getColumnIndex('source'))),
      sourceRef: resultSet.isColumnNull(sourceRefIdx) ? null : resultSet.getString(sourceRefIdx),
      sortOrder: resultSet.getLong(resultSet.getColumnIndex('sortOrder')),
      ganttOrder: resultSet.isColumnNull(ganttOrderIdx) ? null : resultSet.getLong(ganttOrderIdx),
      deleted: resultSet.getLong(resultSet.getColumnIndex('deleted')) === 1,
      createdAt: resultSet.getLong(resultSet.getColumnIndex('createdAt')),
      updatedAt: resultSet.getLong(resultSet.getColumnIndex('updatedAt'))
    };
    return item;
  }

  /** source 列读出来是 string，这里收窄回 EntrySource 字面量联合，避免类型断言 */
  private toEntrySource(value: string): EntrySource {
    if (value === 'timetable') {
      return 'timetable';
    }
    if (value === 'longterm') {
      return 'longterm';
    }
    return 'manual';
  }

  /** 按条件查课表规则并逐行映射，查完关闭结果集 */
  private async queryRules(predicates: relationalStore.RdbPredicates): Promise<TimetableRule[]> {
    const store = this.getStore();
    const resultSet = await store.query(predicates);
    const list: TimetableRule[] = [];
    try {
      while (resultSet.goToNextRow()) {
        list.push(this.rowToRule(resultSet));
      }
    } finally {
      resultSet.close();
    }
    return list;
  }

  /** 一行结果集 → TimetableRule */
  private rowToRule(resultSet: relationalStore.ResultSet): TimetableRule {
    const rule: TimetableRule = {
      id: resultSet.getString(resultSet.getColumnIndex('id')),
      weekday: resultSet.getLong(resultSet.getColumnIndex('weekday')),
      periodFrom: resultSet.getLong(resultSet.getColumnIndex('periodFrom')),
      periodTo: resultSet.getLong(resultSet.getColumnIndex('periodTo')),
      name: resultSet.getString(resultSet.getColumnIndex('name')),
      location: resultSet.getString(resultSet.getColumnIndex('location')),
      weeks: this.toWeekRepeatMode(resultSet.getString(resultSet.getColumnIndex('weeks'))),
      weekFrom: resultSet.getLong(resultSet.getColumnIndex('weekFrom')),
      weekTo: resultSet.getLong(resultSet.getColumnIndex('weekTo')),
      timeStart: resultSet.getString(resultSet.getColumnIndex('timeStart'))
    };
    return rule;
  }

  /** 一行结果集 → TimetableException，可空列 weekday 先判 isColumnNull 再取值 */
  private rowToException(resultSet: relationalStore.ResultSet): TimetableException {
    const weekdayIdx = resultSet.getColumnIndex('weekday');
    const exception: TimetableException = {
      id: resultSet.getString(resultSet.getColumnIndex('id')),
      date: resultSet.getLong(resultSet.getColumnIndex('date')),
      type: this.toExceptionType(resultSet.getString(resultSet.getColumnIndex('type'))),
      weekday: resultSet.isColumnNull(weekdayIdx) ? null : resultSet.getLong(weekdayIdx)
    };
    return exception;
  }

  /** weeks 列读出来是 string，这里收窄回 WeekRepeatMode 字面量联合，避免类型断言 */
  private toWeekRepeatMode(value: string): WeekRepeatMode {
    if (value === 'odd') {
      return 'odd';
    }
    if (value === 'even') {
      return 'even';
    }
    return 'every';
  }

  /** type 列读出来是 string，这里收窄回 ExceptionType 字面量联合，避免类型断言 */
  private toExceptionType(value: string): ExceptionType {
    if (value === 'useWeekday') {
      return 'useWeekday';
    }
    return 'noClass';
  }
}
