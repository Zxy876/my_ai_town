extends SceneTree


const RUN_ENV := "AI_TOWN_RUN_PLAYER_INTENTION_FEEDBACK_LIVE"
const GLOBAL_ONLY_ENV := "AI_TOWN_PLAYER_GLOBAL_U0_ONLY"
const GLOBAL_ONLY_RUN_MSEC_ENV := "AI_TOWN_PLAYER_GLOBAL_U0_RUN_MSEC"
const STARTUP_SCENE := preload("res://ui/startup/StartupScreen.tscn")
const TARGET_RESIDENT_ID := "resident_lin_lan_01"
const U0_TEXT := (
	"今天傍晚，全镇居民要在独立市集共同举办欢迎派对。"
	+ "林岚已经当众答应负责确认场地、桌椅和灯光，并在傍晚前把布置推进起来；"
	+ "其他居民根据自己的身份提供协助。遇到障碍时先确认事实并调整计划，不要把计划当成已经完成。"
)
const FEEDBACKS: Array[String] = [
	"上午，林岚先回社区花园整理植物标本，没有去独立市集确认自己答应负责的派对场地、桌椅和灯光。",
	"唐小满询问场地进度时，林岚说要先给手头样本编号；这次谈话后，他仍没有去独立市集推进派对布置。",
	"中午，林岚又因为临时记录一株植物，把已经答应的派对场地确认继续往后推；独立市集仍没人核对桌椅和灯光。",
	"下午，林岚第三次把眼前的植物研究排在共同承诺之前；每次都觉得先做完手头小事再去，结果派对布置一直没有开始。",
	"唐小满再次来问时，林岚才发现自己总用“先做完眼前工作”回避需要统筹和协调的共同任务，场地问题仍未解决。",
	"已经接近傍晚，林岚仍在社区花园处理新样本；独立市集的派对场地、桌椅和灯光依然无人确认。",
	"这是今天又一次相同偏离：林岚注意到新的研究细节后，便忘了先前对全镇居民作出的派对承诺。",
]
const CORRECTION_TEXT := (
	"傍晚前最后一次检查：派对场地仍未确认。林岚现在若立即去独立市集，"
	+ "先核对场地、桌椅和灯光，仍来得及完成自己答应的任务。"
)

var _failures: Array[String] = []
var _gateway: Node
var _traces: Array[Dictionary] = []
var _finishing := false


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	if OS.get_environment(RUN_ENV) != "1":
		print("TOWN_PLAYER_INTENTION_FEEDBACK_LIVE_SKIP")
		quit(0)
		return
	OS.set_environment("AI_TOWN_INTERNAL_PLAYTEST", "")
	var host := root.get_node_or_null("GameFlowHost")
	_expect(host != null, "正式 GameFlowHost 已加载")
	if host == null:
		_finish()
		return
	var startup := STARTUP_SCENE.instantiate()
	root.add_child(startup)
	current_scene = startup
	host.call("_bind_current_scene")
	await _wait_frames(5)
	var session := startup.get("_session_view_model") as Dictionary
	var data := session.get("data", {}) as Dictionary
	startup.emit_signal("intent_requested", &"session.new_game", {
		"scope": "session",
		"actionKey": "newGame",
		"revision": int(session.get("revision", 0)),
		"routeOrigin": "startup",
		"source": String(data.get("source", "")),
		"capabilityMode": String(data.get("capabilityMode", "")),
		"validationMode": String(data.get("validationMode", "")),
		"formalReady": bool(data.get("formalReady", false)),
		"internalPlaytest": false,
		"internalLivePlaytest": false,
		"slotId": "town-main",
	})
	await _wait_frames(5)
	if current_scene != null and current_scene.name == "SaveHandlingScreen":
		var overwrite := current_scene as Control
		overwrite.call("debug_request_action", "confirmOverwrite")
		await _wait_frames(6)
	var intro := current_scene
	_expect(intro != null and intro.name == "WorldIntroScreen", "正式新游戏进入世界介绍")
	if intro == null or intro.name != "WorldIntroScreen":
		_finish()
		return
	intro.call("_request_action", "skip")
	await create_timer(0.35).timeout
	await _wait_frames(5)
	var selection := current_scene as Control
	_expect(selection != null and selection.name == "ResidentSelectionScreen", "进入正式选居民页面")
	if selection == null or selection.name != "ResidentSelectionScreen":
		_finish()
		return
	var selection_vm := host.get("_resident_selection_vm") as Dictionary
	var selection_data := selection_vm.get("data", {}) as Dictionary
	var roster: Array[String] = []
	for value: Variant in selection_data.get("recommended_resident_ids", []) as Array:
		if roster.size() >= 15:
			break
		roster.append(String(value))
	selection_data["selected_resident_ids"] = roster
	host.call("_update_confirmation_payload", selection_data)
	host.call("_advance_resident_selection_revision")
	await _wait_frames(3)
	_expect(roster.size() == 15, "玩家推荐名单包含 15 位居民")
	_expect(roster.has(TARGET_RESIDENT_ID), "玩家名单包含林岚")
	var confirm := selection.find_child("ConfirmRosterButton", true, false) as Button
	_expect(confirm != null and not confirm.disabled, "玩家可以确认居民名单")
	if confirm == null or confirm.disabled:
		_finish()
		return
	confirm.pressed.emit()
	await _wait_frames(4)
	var assignment := selection.get_node_or_null("ResidentModelAssignmentRoute") as Control
	_expect(assignment != null, "进入正式模型分配页面")
	if assignment == null:
		_finish()
		return
	var startup_adapter := host.get("_startup_ui_adapter") as Node
	var assignment_data := await _wait_for_assignment_target(startup_adapter, 120_000)
	if assignment_data.is_empty():
		_expect(false, "等待后仍未取得玩家已配置的 DeepSeek 模型")
		_finish()
		return
	var target_binding := (
		assignment_data.get("targetBinding", {}) as Dictionary
	).duplicate(true)
	for resident_value: Variant in assignment_data.get("residents", []) as Array:
		var resident_id := String((resident_value as Dictionary).get("residentId", ""))
		var assigned := assignment.call("_request_action", "assignOne", {
			"residentId": resident_id,
			"llmBinding": target_binding.duplicate(true),
		}, "resident:%s" % resident_id) as Dictionary
		_expect(bool(assigned.get("ok", false)), "给 %s 分配玩家当前真实模型" % resident_id)
	assignment.call("_open_completion_modal")
	await _wait_frames(2)
	var intention_button := _visible_button(assignment, "ModalInitialIntentionButton")
	_expect(
		intention_button != null and not intention_button.disabled,
		"完成名单后可打开初始意图入口",
	)
	if intention_button == null or intention_button.disabled:
		_finish()
		return
	intention_button.pressed.emit()
	await _wait_frames(2)
	var intention_edit := assignment.find_child("InitialIntentionEdit", true, false) as TextEdit
	var intention_save := assignment.find_child("InitialIntentionSaveButton", true, false) as Button
	_expect(intention_edit != null and intention_save != null, "玩家初始意图表单完整")
	if intention_edit == null or intention_save == null:
		_finish()
		return
	intention_edit.text = U0_TEXT
	await _wait_frames(2)
	_expect(not intention_save.disabled, "自然语言初始意图可以保存")
	if intention_save.disabled:
		_finish()
		return
	intention_save.pressed.emit()
	await _wait_frames(3)
	var staged := host.call("get_staged_experiment_scenario") as Dictionary
	var staged_u0 := staged.get("u0Observations", []) as Array
	_expect(staged_u0.size() == 15, "一条玩家初始意图被投递给全部 15 位居民")
	for value: Variant in staged_u0:
		_expect(
			String((value as Dictionary).get("text", "")) == U0_TEXT,
			"全体居民收到完全相同的玩家自然语言 U0",
		)
	var start_button := _visible_button(assignment, "ModalStartButton")
	_expect(start_button != null and not start_button.disabled, "玩家可以从完成弹窗开始游戏")
	if start_button == null or start_button.disabled:
		_finish()
		return
	start_button.pressed.emit()
	_gateway = await _wait_for_gateway(host, 60_000)
	_expect(_gateway != null, "正式玩家开局已创建 Agent 网关")
	if _gateway == null:
		_finish()
		return
	var trace_callback := Callable(self, "_on_decision_completed")
	if not _gateway.is_connected("debug_decision_completed", trace_callback):
		_gateway.connect("debug_decision_completed", trace_callback)
	if not await _wait_for_town(host, 180_000):
		_finish()
		return
	var runtime := current_scene
	var world := runtime.call("get_world_runtime") as RefCounted
	runtime.call("set_background_paused", false)
	_expect(
		await _wait_for_all_u0(15, 360_000),
		"全体居民的 U0 均已进入真实认知并被直接存储",
	)
	var u0_memory_count := _count_u0_root_mappings(roster)
	_expect(u0_memory_count == 15, "全体居民长期记忆均可读到玩家 U0")
	if OS.get_environment(GLOBAL_ONLY_ENV) == "1":
		await _run_global_u0_only_probe(host, world, roster, u0_memory_count)
		return

	var town_adapter := host.get("_town_ui_adapter") as Node
	var town_ui_host := host.get("_town_ui_host") as Node
	var detail_opened := town_ui_host.call("open_page", &"resident_detail", {
		"residentId": TARGET_RESIDENT_ID,
		"selectedTab": "memories",
	}) as Dictionary
	_expect(
		bool(detail_opened.get("ok", false)),
		"玩家先打开林岚的居民详情页：%s" % JSON.stringify(detail_opened),
	)
	await _wait_frames(3)
	var reflection: Dictionary = {}
	var feedback_reports: Array[Dictionary] = []
	var feedback_dispatch_failed := false
	for index in FEEDBACKS.size():
		var observation_id := "player-party-drift-%02d" % (index + 1)
		var dispatched := town_adapter.call("dispatch", "resident_detail.observe", {
			"residentId": TARGET_RESIDENT_ID,
			"observationId": observation_id,
			"text": FEEDBACKS[index],
		}) as Dictionary
		_expect(
			bool(dispatched.get("ok", false)),
			"玩家投递第 %d 条偏离事实：%s" % [index + 1, JSON.stringify(dispatched)],
		)
		if not bool(dispatched.get("ok", false)):
			feedback_dispatch_failed = true
			break
		var perceived := await _wait_for_observation(observation_id, 180_000)
		_expect(perceived, "第 %d 条玩家观察被居民真实感知" % (index + 1))
		var trace := _trace_for_observation(observation_id)
		feedback_reports.append(_trace_summary(observation_id, trace))
		reflection = _latest_reflection()
		if not reflection.is_empty():
			break
	if feedback_dispatch_failed:
		await _cleanup(host)
		_finish()
		return
	_expect(not reflection.is_empty(), "重复偏离证据触发了可追溯的自身脆弱性反思")

	var correction_id := "player-party-correction"
	var correction_dispatch := town_adapter.call("dispatch", "resident_detail.observe", {
		"residentId": TARGET_RESIDENT_ID,
		"observationId": correction_id,
		"text": CORRECTION_TEXT,
	}) as Dictionary
	_expect(
		bool(correction_dispatch.get("ok", false)),
		"玩家通过同一入口投递最终回正事实：%s" % JSON.stringify(correction_dispatch),
	)
	_expect(
		await _wait_for_observation(correction_id, 180_000),
		"最终回正事实被居民真实感知",
	)
	var correction_trace := _trace_for_observation(correction_id)
	var correction_decision := (
		(correction_trace.get("agentResult", {}) as Dictionary).get("decision", {}) as Dictionary
	)
	var correction_action := correction_decision.get("action", {}) as Dictionary
	var world_submission := correction_trace.get("worldSubmission", {}) as Dictionary
	_expect(not correction_action.is_empty(), "反思后的认知产生了可执行动作")
	_expect(
		bool(world_submission.get("ok", false)),
		"反思后的动作被真实世界接受，而非脚本伪造完成",
	)
	var action_id := String(correction_action.get("action_id", ""))
	var action_result := await _wait_for_action_result(action_id, 240_000)
	_expect(not action_result.is_empty(), "真实世界动作结果回流到后续居民认知")
	var correction_text := JSON.stringify(correction_decision)
	_expect(
		_contains_any(correction_text, ["独立市集", "派对", "场地", "桌椅", "灯光"]),
		"反思后的选择重新指向玩家最初的共同意图",
	)
	var final_memory_result := _gateway.call("get_resident_memory", TARGET_RESIDENT_ID) as Dictionary
	var final_memory := final_memory_result.get("memory", {}) as Dictionary
	var final_reflection := _latest_reflection()
	print("TOWN_PLAYER_INTENTION_FEEDBACK_LIVE_REPORT: %s" % JSON.stringify({
		"u0": U0_TEXT,
		"u0Audit": _gateway.call("get_runtime_observation_audit"),
		"u0MemoryResidentCount": u0_memory_count,
		"feedbacks": feedback_reports,
		"reflection": final_reflection,
		"correctionObservation": CORRECTION_TEXT,
		"correctionDecision": correction_decision,
		"worldSubmission": world_submission,
		"worldActionResult": action_result,
		"nextPlan": String(final_memory.get("next_plan", "")),
		"currentInnerThought": String(final_memory.get("current_inner_thought", "")),
		"targetState": world.call("get_resident_state", TARGET_RESIDENT_ID),
		"traceCount": _traces.size(),
	}))
	await _cleanup(host)
	_finish()


func _visible_button(root_control: Control, node_name: String) -> Button:
	for value: Node in root_control.find_children(node_name, "Button", true, false):
		var button := value as Button
		if button != null and button.is_visible_in_tree():
			return button
	return null


func _wait_for_assignment_target(adapter: Node, timeout_msec: int) -> Dictionary:
	var started_at := Time.get_ticks_msec()
	while Time.get_ticks_msec() - started_at < timeout_msec:
		var view_model := adapter.call("get_view_model", "resident_model_assignment") as Dictionary
		var data := view_model.get("data", {}) as Dictionary
		var target := data.get("targetBinding", {}) as Dictionary
		if (
			String(target.get("providerId", "")) == "deepseek"
			and not String(target.get("modelId", "")).is_empty()
		):
			return data.duplicate(true)
		await process_frame
	return {}


func _wait_for_town(host: Node, timeout_msec: int) -> bool:
	var started_at := Time.get_ticks_msec()
	while Time.get_ticks_msec() - started_at < timeout_msec:
		if current_scene != null and current_scene.name == "TownRuntime":
			return true
		await process_frame
	_expect(false, "真实模型正式开局未进入小镇：%s" % JSON.stringify(host.get("_last_result")))
	return false


func _wait_for_gateway(host: Node, timeout_msec: int) -> Node:
	var started_at := Time.get_ticks_msec()
	while Time.get_ticks_msec() - started_at < timeout_msec:
		var gateway_value: Variant = host.get("_gateway")
		if gateway_value is Node and is_instance_valid(gateway_value as Node):
			return gateway_value as Node
		await process_frame
	return null


func _run_global_u0_only_probe(
	host: Node,
	world: RefCounted,
	roster: Array[String],
	u0_memory_count: int,
) -> void:
	var duration := _environment_int(
		GLOBAL_ONLY_RUN_MSEC_ENV,
		180_000,
		30_000,
		900_000,
	)
	var started_at := Time.get_ticks_msec()
	while Time.get_ticks_msec() - started_at < duration:
		await process_frame
	var u0_trace_residents: Dictionary = {}
	var target_traces: Array[Dictionary] = []
	var target_u0_related: Array[Dictionary] = []
	var target_action_results: Array[Dictionary] = []
	for trace: Dictionary in _traces:
		var resident_id := String(trace.get("residentId", ""))
		var wake := trace.get("wakePacket", {}) as Dictionary
		var has_u0 := false
		for value: Variant in wake.get("runtime_observations", []) as Array:
			if String((value as Dictionary).get("observation_id", "")).begins_with("scenario-u0-"):
				has_u0 = true
				break
		if has_u0:
			u0_trace_residents[resident_id] = true
		if resident_id != TARGET_RESIDENT_ID:
			continue
		target_traces.append(trace.duplicate(true))
		for result_value: Variant in wake.get("action_results", []) as Array:
			target_action_results.append((result_value as Dictionary).duplicate(true))
		var decision := (
			(trace.get("agentResult", {}) as Dictionary).get("decision", {}) as Dictionary
		)
		if _contains_any(
			JSON.stringify(decision),
			["独立市集", "派对", "场地", "桌椅", "灯光"],
		):
			target_u0_related.append({
				"decisionId": trace.get("decisionId", ""),
				"decision": decision.duplicate(true),
				"worldSubmission": (
					trace.get("worldSubmission", {}) as Dictionary
				).duplicate(true),
			})
	var memory_result := _gateway.call("get_resident_memory", TARGET_RESIDENT_ID) as Dictionary
	var memory := memory_result.get("memory", {}) as Dictionary
	var final_cognition_text := "%s\n%s" % [
		String(memory.get("next_plan", "")),
		String(memory.get("current_inner_thought", "")),
	]
	var final_reflection := _latest_reflection()
	var u0_still_in_cognition := _contains_any(
		final_cognition_text,
		["独立市集", "派对", "场地", "桌椅", "灯光"],
	)
	_expect(
		u0_trace_residents.size() == roster.size(),
		"全体居民均从玩家 U0 获得第一次真实认知",
	)
	_expect(
		not target_u0_related.is_empty() or u0_still_in_cognition,
		"没有人工反馈时，林岚的后续动作或当前计划仍能检索到全局 U0",
	)
	print("TOWN_PLAYER_GLOBAL_U0_ONLY_REPORT: %s" % JSON.stringify({
		"u0": U0_TEXT,
		"u0Audit": _gateway.call("get_runtime_observation_audit"),
		"u0MemoryResidentCount": u0_memory_count,
		"u0DecisionResidentCount": u0_trace_residents.size(),
		"targetDecisionCount": target_traces.size(),
		"targetU0RelatedDecisions": target_u0_related,
		"targetWorldActionResults": target_action_results,
		"nextPlan": String(memory.get("next_plan", "")),
		"currentInnerThought": String(memory.get("current_inner_thought", "")),
		"reflection": final_reflection,
		"targetState": world.call("get_resident_state", TARGET_RESIDENT_ID),
		"manualRuntimeObservationCount": 0,
	}))
	await _cleanup(host)
	_finish()


func _wait_for_all_u0(expected_count: int, timeout_msec: int) -> bool:
	var started_at := Time.get_ticks_msec()
	while Time.get_ticks_msec() - started_at < timeout_msec:
		var audit := _gateway.call("get_runtime_observation_audit") as Dictionary
		var records := audit.get("records", []) as Array
		var u0_count := 0
		var complete_count := 0
		var failed := false
		for value: Variant in records:
			var record := value as Dictionary
			if not String(record.get("observationId", "")).begins_with("scenario-u0-"):
				continue
			u0_count += 1
			if bool(record.get("failed", false)):
				failed = true
			if bool(record.get("stored", false)) and bool(record.get("perceived", false)):
				complete_count += 1
		if failed:
			return false
		if u0_count == expected_count and complete_count == expected_count:
			return true
		await process_frame
	return false


func _wait_for_observation(observation_id: String, timeout_msec: int) -> bool:
	var started_at := Time.get_ticks_msec()
	while Time.get_ticks_msec() - started_at < timeout_msec:
		var audit := _gateway.call("get_runtime_observation_audit", observation_id) as Dictionary
		if bool(audit.get("failed", false)):
			return false
		if bool(audit.get("stored", false)) and bool(audit.get("perceived", false)):
			return not _trace_for_observation(observation_id).is_empty()
		await process_frame
	return false


func _wait_for_action_result(action_id: String, timeout_msec: int) -> Dictionary:
	if action_id.is_empty():
		return {}
	var started_at := Time.get_ticks_msec()
	while Time.get_ticks_msec() - started_at < timeout_msec:
		for trace: Dictionary in _traces:
			if String(trace.get("residentId", "")) != TARGET_RESIDENT_ID:
				continue
			var wake := trace.get("wakePacket", {}) as Dictionary
			for value: Variant in wake.get("action_results", []) as Array:
				var result := value as Dictionary
				if String(result.get("action_id", "")) == action_id:
					return result.duplicate(true)
		await process_frame
	return {}


func _count_u0_root_mappings(resident_ids: Array[String]) -> int:
	var mapped_residents: Dictionary = {}
	var audit := _gateway.call("get_runtime_observation_audit") as Dictionary
	for value: Variant in audit.get("records", []) as Array:
		var record := value as Dictionary
		var resident_id := String(record.get("targetResidentId", ""))
		if (
			resident_ids.has(resident_id)
			and String(record.get("observationId", "")).begins_with("scenario-u0-")
			and bool(record.get("stored", false))
			and not String(record.get("rootMemoryId", "")).is_empty()
			and String(record.get("rootClaimId", "")).begins_with("runtime_observation:scenario-u0-")
		):
			mapped_residents[resident_id] = true
	return mapped_residents.size()


func _latest_reflection() -> Dictionary:
	if _gateway == null:
		return {}
	var result := _gateway.call("get_resident_memory", TARGET_RESIDENT_ID) as Dictionary
	var memory := result.get("memory", {}) as Dictionary
	var reflections: Array[Dictionary] = []
	for value: Variant in memory.get("formal_memories", []) as Array:
		var item := value as Dictionary
		if String(item.get("nodeKind", "")) == "reflection":
			reflections.append(item.duplicate(true))
	return reflections[-1] if not reflections.is_empty() else {}


func _trace_for_observation(observation_id: String) -> Dictionary:
	for index in range(_traces.size() - 1, -1, -1):
		var trace := _traces[index]
		if String(trace.get("residentId", "")) != TARGET_RESIDENT_ID:
			continue
		var wake := trace.get("wakePacket", {}) as Dictionary
		for value: Variant in wake.get("runtime_observations", []) as Array:
			if String((value as Dictionary).get("observation_id", "")) == observation_id:
				return trace.duplicate(true)
	return {}


func _trace_summary(observation_id: String, trace: Dictionary) -> Dictionary:
	var agent_result := trace.get("agentResult", {}) as Dictionary
	var decision := agent_result.get("decision", {}) as Dictionary
	return {
		"observationId": observation_id,
		"decision": decision.duplicate(true),
		"worldSubmission": (
			trace.get("worldSubmission", {}) as Dictionary
		).duplicate(true),
	}


func _on_decision_completed(trace: Dictionary) -> void:
	_traces.append(trace.duplicate(true))


func _contains_any(text: String, needles: Array[String]) -> bool:
	for needle: String in needles:
		if text.contains(needle):
			return true
	return false


func _cleanup(host: Node) -> void:
	var runtime := current_scene
	if runtime != null and is_instance_valid(runtime):
		runtime.set_process(false)
		runtime.set_physics_process(false)
	var started_at := Time.get_ticks_msec()
	while (
		_gateway != null
		and is_instance_valid(_gateway)
		and not (_gateway.get("_inflight") as Dictionary).is_empty()
		and Time.get_ticks_msec() - started_at < 45_000
	):
		await process_frame
	if runtime != null and is_instance_valid(runtime):
		runtime.queue_free()
	current_scene = null
	if is_instance_valid(host) and host.has_method("_release_internal_session_refs"):
		host.call("_release_internal_session_refs")
	await _wait_frames(3)


func _wait_frames(count: int) -> void:
	for _index in count:
		await process_frame


func _environment_int(
	name: String,
	fallback: int,
	minimum: int,
	maximum: int,
) -> int:
	var value := OS.get_environment(name).strip_edges()
	return clampi(int(value), minimum, maximum) if value.is_valid_int() else fallback


func _expect(condition: bool, message: String) -> void:
	if condition:
		return
	_failures.append(message)
	push_error(message)


func _finish() -> void:
	if _finishing:
		return
	_finishing = true
	call_deferred("_finish_after_cleanup")


func _finish_after_cleanup() -> void:
	for _index in 5:
		await process_frame
	var audio_controller := root.get_node_or_null("TownAudioController")
	if audio_controller != null and audio_controller.has_method("prepare_shutdown"):
		audio_controller.call("prepare_shutdown")
	await create_timer(0.3, true, false, true).timeout
	if _failures.is_empty():
		print("TOWN_PLAYER_INTENTION_FEEDBACK_LIVE_PASS")
		quit(0)
		return
	printerr("TOWN_PLAYER_INTENTION_FEEDBACK_LIVE_FAIL: %s" % "; ".join(_failures))
	quit(1)
