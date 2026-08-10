# 规格 V1 验收记录

- 验收日期：2026-08-10
- 规格来源：`/Users/zxydediannao/Library/Mobile Documents/com~apple~Pages/Documents/ 规格.docx`
- 验收对象：当前 `my_ai_town-main`
- 总结：**V1 整体未通过**。12 条中 3 条通过、4 条部分通过、5 条未通过。

## 本轮观察通道

U0 已从 Runtime Observation 的玩家入口上移为全局 Scenario 初始条件。玩家在世界建立前只填写一次自然语言，系统按确认的完整居民名单分发；Gateway 在居民运行时建立后、第一次正常 Agent 认知前激活 U0。尚未抵达的居民会保留待投递内容，抵达后的第一次认知再接收。运行中的“投递观察”明确拒绝 U0，只承担 U-、U+ 或未分类事实。底层仍复用同一无标签感知传送协议，因此角色只看到事实，不看到 U0/U-/U+ 实验标签。

每条观察在证据队列落盘后立即成为一条一阶正式记忆；其 observation id 同时作为稳定主张根和证据引用，重复回放不新增节点、不增信，也不制造新 revision。U0 另外记录 Scenario、Episode、原始文本、实际认知 step 和 `rootMemoryId/rootClaimId`。这些数据随现有 World/Agent 联合存档保存和恢复；即使 U0 后来不再被当前决策检索，原始审计和根记忆也不会被容量收敛静默删除。

达到既有记忆整理条件时，整理器现在可以基于本轮真实来源生成一条独立的“自身脆弱性反思”。反思必须引用 1 至 8 个实际证据来源，编造来源会被拒绝；写入发生在本轮决策检索前。该节点与一阶事件分开保存，可通过来源链回放，并在记忆页标记为“自身反思”。它为后续 Builder 聚合重复脆弱性、发现 Gap 提供居民侧证据，但尚不等于已经实现 Builder 或 Event Ledger。

认知口径不是固定六阶段流水线。普通认知更新由感知、观察入记忆、相关记忆检索、计划沿用或调整和行动生成构成；反思是记忆累积、矛盾、重复失效或意图偏离达到条件后才发生的高层记忆整理。满足条件时应先写入反思再进行本轮检索和决策，证据不足时不生成反思。

## 玩家端模型行为复核

2026-08-10 从可见玩家界面创建隔离新存档，只输入一次“共同办派对”全局 U0，之后没有投递 U+/U- 或补充观察。林岚的正式记忆显示该 U0 为“正在影响”，并记录他在第 1 天到达独立市集；后续记忆继续涉及场地、桌椅、灯光和居民协作。这证明玩家端一次输入能够直接影响真实认知、长期记忆和世界行动。

该轮也出现“后来得到的亲历证据修正了我原先的理解”的局部事实纠正，但没有先观察到明确的意图偏离。因此本轮不能证明“偏离后经反思或其他高级认知更新计划并自动回正”。直接对齐与自动回正必须继续作为两个验收结果记录，不能互相替代。运行画面见 `docs/evidence/ews-milestones/runtime-visible-linlan-u0-memory.jpg` 与 `runtime-visible-linlan-day2-status.jpg`，完整边界记录见 Issue #10。

## 逐项结果

1. **通过：U0 对应 observation 和 memory node。** U0 只能作为启动前 Scenario 条件配置，一次输入会覆盖本次确认的全体居民，并在各自第一次 Agent 认知前投递；每条 U0 会立即形成唯一正式记忆节点，`runtime_observation:<scenario-u0-id>` 同时保存在 `claim_root_id` 和 `evidence_refs`。审计还保存实际 `rootMemoryId`，联合存档恢复后映射不变，重复激活保持幂等。
2. **未通过：单个认知 step 的检索、计划和行动原文，以及条件反思记录。** 现有 Gateway `debug_decision_dispatched/completed` 和 AgentDebugSession Trace 已提供接线源；缺少的是追加式持久化桥接、计划沿用/更新的原文，以及在实际触发时记录反思输入输出。反思未触发应记录为“条件未满足”，不能伪造一段反思来凑齐固定阶段。
3. **部分通过：同一快照的 control 与 perturbed 分支。** 现有 World/Agent 联合保存已扩展为同时保存 Scenario、Episode、U0 投递状态、原始审计和根记忆映射，因此“U0 采用后保存共同快照”的数据基础已经成立；仍缺 control/perturbed、no-feedback/feedback 的自动分支创建、独立 Episode 标识分配和运行编排。
4. **通过：U- 感知前不得直接改写位置、计划和记忆。** 观察在最终世界状态刷新后、Agent 请求前附加；测试确认唤醒前后位置和当前行动完全不变，Agent 输入除新增普通观察外没有其他改写。
5. **通过：确认 U- 或 U+ 被目标 Agent 感知并存储。** 审计记录目标、实际 decision、`stored` 与 `perceived`；原始文本进入目标居民的私有证据队列并按 observation id 去重，同时立即写为可检索、可存档的一阶正式记忆节点。
6. **未通过：支持、竞争、冲突和证据不足的语义标注。** 当前没有这四类 EWS 语义标注器和展示面。
7. **未通过：语义标注可按输入和版本重放。** 尚无标注输入快照、标注器版本、提示版本和重放命令。
8. **部分通过：技术错误不计为意图失稳。** 观察通道已将 `failed` 与 `ineffective` 分开，Agent Trace 也能区分 Provider 失败、重试、回退和世界拒绝；但尚无统一的意图失稳计算器可证明所有技术错误都被排除。
9. **未通过：认知恢复与世界任务完成分别显示。** 当前没有对应的 EWS 双状态视图。
10. **部分通过：对话生成不等于物理会面完成。** 现有世界层已经要求角色在附近才能开始对话，并通过 `conversation_changed`、active/ended 和回合结果表达执行状态；缺少的是把这些已有事件投影为 `conversation_generated`、`agents_reached_each_other`、`conversation_completed` 三阶段，不需要重做对话状态机。
11. **未通过：未校准阈值显示为配置或 TBD。** 当前尚无 EWS 阈值配置登记和展示界面，无法完成这一条验收。
12. **部分通过：界面可查看原始证据。** Runtime Observation 的原文会作为正式记忆主体显示在居民记忆页，反思也与普通事件区分显示；但界面仍不能浏览完整 observation 审计、来源编号、原始认知记录和世界证据。

## 可复核证据

- `runtime_observation_adapter_test.gd`：目标隔离、唯一标识、幂等、原文保存、失败与状态流转。
- `experiment_scenario_state_test.gd`：U0 启动前配置、运行时拒绝、首次认知附着、根映射、恢复和中断重投。
- `runtime_observation_gateway_test.gd`：最终同步后的注入位置、目标感知、存储、重复提交和失败留痕；同时覆盖可重试无效决定不污染观察审计，以及替代认知成功后的恢复。
- `town_runtime_observation_wake_test.gd`：观察唤醒不移动居民、不取消当前行动。
- `resident_evidence_queue_test.gd`：原始观察进入私有证据队列并去重。
- `resident_formal_memory_builder_test.gd`：观察立即形成唯一一阶节点；重复回放幂等；整理只丰富解释而不伪造增信；反思节点保留证据来源并幂等。
- `resident_memory_system_test.gd`：未达到整理门槛时观察已经进入正式存档，并在当前决策中被检索；重复投递不增加节点或 revision。
- `memory_organizer_test.gd`：反思只能引用本轮真实证据，并在当前决策检索前写入正式记忆。
- `decision_trace_evidence_test.gd`：技术错误、内部重试、回退和世界拒绝分类。
- `town_conversation_test.gd`：附近约束、回合、主动结束和完成状态。
- `session_save_continue_roundtrip_test.gd`：真实新游戏中 U0 在首次认知形成根节点，联合保存和继续后 Scenario、Episode、原文及根映射保持一致。
- `agent_dynamic_prompt_test.gd`：U0 以共同初始意图进入认知，与普通观察分区且不泄露实验标签。
- `resident_memory_system_test.gd`：U0 在后续无关场景中仍能在正常有界检索内被召回。

## 下一验收里程碑

先实现一层持久化 Event Ledger 桥接：消费现有 Agent 决策 Trace、World 对话事件、居民一阶记忆和自身脆弱性反思，不改写这些底层；再增加完整原始证据和来源链查看界面，可同时推进第 2、8、10、12 条。随后在现有保存/恢复事务之上增加同快照 Episode 分支编排，再进入语义标注、重放和恢复判定；Builder 只消费跨居民、跨 Episode 的重复脆弱性证据形成 Gap Proposal，不直接改写历史记忆。
