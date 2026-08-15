extends SceneTree


const INTERNAL_CATALOG := preload(
	"res://world/presentation/session/TownInternalPlaytestCatalog.gd"
)
const COMPILER := preload(
	"res://world/presentation/session/TownNewGameOpeningCompiler.gd"
)
const BOOTSTRAP := preload(
	"res://world/presentation/session/TownSessionBootstrap.gd"
)
const PROVIDER_SERVICE := preload(
	"res://world/integration/TownAgentProviderService.gd"
)
const GATEWAY := preload(
	"res://world/integration/TownWorldAgentGateway.gd"
)
const TOWN_RUNTIME_SCENE := preload(
	"res://world/presentation/town_runtime/TownRuntime.tscn"
)
const STORE := preload(
	"res://world/presentation/session/TownSessionSaveStore.gd"
)
const RUNTIME_GATE := preload(
	"res://world/presentation/session/TownSessionRuntimeGate.gd"
)
const COORDINATOR := preload(
	"res://world/presentation/session/TownSessionSaveCoordinator.gd"
)

var _failures: Array[String] = []
var _checks := 0


class ResultCollector:
	extends RefCounted
	var result: Dictionary = {}

	func collect(value: Dictionary) -> void:
		result = value.duplicate(true)


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	DisplayServer.window_set_size(Vector2i(1920, 1080))
	root.size = Vector2i(1920, 1080)
	var identity := "%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	var slot_id := "roundtrip-slot-%s" % identity
	var session_id := "roundtrip-session-%s" % identity
	var test_root := "user://tests/town_session_saves/roundtrip_%s" % identity
	var world_data := _read_json("res://world/data/town/town_world.json")
	var selection_vm := INTERNAL_CATALOG.build_view_model("fake", "fake")
	var draft := (
		(selection_vm.get("data", {}) as Dictionary)
		.get("confirmation_payload", {}) as Dictionary
	).duplicate(true)
	var catalog := INTERNAL_CATALOG.build_catalog(world_data, selection_vm)
	var compiled := COMPILER.compile(draft, world_data, catalog) as Dictionary
	_expect_ok(compiled, "正式组合器可生成完整开局配置")
	if compiled.get("ok") != true:
		_finish()
		return
	var bindings := compiled.get("residentBindings", []) as Array[Dictionary]
	var identities := _identities(bindings)
	var u0_target_id := String(identities[0].get("residentId", ""))
	var request_host := Node.new()
	request_host.name = "SaveContinueRoundtripRequestHost"
	root.add_child(request_host)
	var provider_service: RefCounted = PROVIDER_SERVICE.new()
	_expect_ok(provider_service.call("configure", {
		"capabilityMode": "development",
		"source": "placeholder",
		"allowFake": true,
		"providerConfigs": {},
	}, request_host) as Dictionary, "离线居民模型服务可用于存档闭环")

	var source_gateway: Node = GATEWAY.new()
	var source_runtime: Node = TOWN_RUNTIME_SCENE.instantiate()
	var bootstrap: RefCounted = BOOTSTRAP.new()
	var collector := ResultCollector.new()
	var accepted := bootstrap.call(
		"begin_new_game_from_catalog",
		draft,
		world_data,
		catalog,
		provider_service,
		source_gateway,
		source_runtime,
		{
			"worldStartMode": "development",
			"internalPlaytest": true,
			"sessionId": session_id,
			"slotId": slot_id,
			"requestHost": request_host,
			"useLiveModel": false,
			"enablePlayerAvatar": false,
			"experimentScenario": {
				"scenarioId": "roundtrip-hospital-intention",
				"episodeId": "common-root",
				"u0Observations": [{
					"targetResidentId": u0_target_id,
					"text": "我建立诊所，是为了让每位来访者都能及时得到照料。",
				}],
			},
		},
		collector.collect,
	) as Dictionary
	_expect_equal(accepted.get("accepted"), true, "新游戏请求被正式组合器接收")
	_expect_ok(collector.result, "源小镇完成启动")
	if collector.result.get("ok") != true:
		source_runtime.free()
		request_host.queue_free()
		_finish()
		return
	root.add_child(source_runtime)
	await _wait_frames(4)
	_expect_ok(
		source_runtime.call("get_startup_result") as Dictionary,
		"源小镇完成场景挂载",
	)
	var u0_audit := await _wait_for_u0_root_mapping(source_gateway)
	_expect(
		not u0_audit.is_empty(),
		"U0 在第一次认知后形成可追溯根记忆映射；审计=%s" % [
			source_gateway.call("get_runtime_observation_audit"),
		],
	)
	_expect_equal(u0_audit.get("targetResidentId"), u0_target_id, "U0 只进入指定居民")
	_expect(
		String(u0_audit.get("rootMemoryId", "")).begins_with("memory-"),
		"U0 审计记录真实正式记忆编号",
	)
	_expect_equal(u0_audit.get("status"), "perceived", "同步返回不会让 U0 状态倒退")
	var source_world: RefCounted = source_runtime.call("get_world_runtime")
	var source_agent: RefCounted = source_gateway.call("get_agent_save_participant")
	var store: RefCounted = STORE.new()
	_expect_ok(
		store.call("configure_test_root", test_root) as Dictionary,
		"闭环测试存档目录可配置",
	)
	var source_gate: RefCounted = RUNTIME_GATE.new()
	_expect_ok(source_gate.call("configure", source_runtime) as Dictionary, "源小镇事务锁可配置")
	var save_coordinator: RefCounted = COORDINATOR.new()
	_expect_ok(save_coordinator.call(
		"configure",
		store,
		source_world,
		source_agent,
		source_gate,
	) as Dictionary, "成对存档协调器可配置")
	var session_config := {
		"mode": "new_game",
		"sessionId": session_id,
		"openingConfig": (
			compiled.get("openingConfig", {}) as Dictionary
		).duplicate(true),
		"residentIdentities": identities.duplicate(true),
		"residentBindings": _saved_bindings(bindings),
		"connectedResidents": _resident_names(identities),
		"worldStartMode": "formal",
		"useLiveModel": true,
		"enablePlayerAvatar": false,
		"enableTestUi": false,
	}
	var experiment_capture := source_gateway.call("capture_experiment_state") as Dictionary
	_expect_ok(experiment_capture, "实验状态可在联合保存前捕获")
	session_config["experimentState"] = (
		experiment_capture.get("experimentState", {}) as Dictionary
	).duplicate(true)
	var saved_time := source_world.call("get_time") as Dictionary
	var saved := save_coordinator.call("save", {
		"slotId": slot_id,
		"sessionId": session_id,
		"residentIdentities": identities.duplicate(true),
		"sessionConfig": session_config.duplicate(true),
		"savedAt": Time.get_datetime_string_from_system(false, false),
		"residentMessages": [],
	}) as Dictionary
	_expect_ok(saved, "世界与居民存档作为同一修订发布")
	var context := saved.get("context", {}) as Dictionary
	_expect_equal(context.get("save_revision"), 1, "首个成对存档修订号为 1")
	var discovered := save_coordinator.call("discover_latest", slot_id) as Dictionary
	_expect_ok(discovered, "刚发布的存档可从正式发现入口读取")
	_expect_equal(
		(discovered.get("summary", {}) as Dictionary).get("saveRevision"),
		1,
		"发现入口返回已发布修订而不是临时文件",
	)

	source_runtime.queue_free()
	await _wait_frames(4)

	var restore_gateway: Node = GATEWAY.new()
	var gateway_configuration := restore_gateway.call("configure_session", {
		"sessionId": session_id,
		"slotId": slot_id,
		"saveRevision": 1,
		"restorePending": true,
		"openingConfig": session_config.get("openingConfig", {}),
		"residentIdentities": identities.duplicate(true),
		"residentBindings": bindings.duplicate(true),
		"capabilityMode": "formal",
		"formalReady": true,
	}, provider_service, request_host) as Dictionary
	_expect_ok(gateway_configuration, "恢复中的居民网关可配置")
	var restored_runtime: Node = TOWN_RUNTIME_SCENE.instantiate()
	_expect_ok(
		restored_runtime.call("configure_agent_gateway", restore_gateway) as Dictionary,
		"恢复网关可注入新小镇",
	)
	var restored_session_config := {
		"mode": "continue",
		"sessionId": session_id,
		"slotId": slot_id,
		"saveRevision": 1,
		"restorePending": true,
		"openingConfig": session_config.get("openingConfig", {}),
		"residentIdentities": identities.duplicate(true),
		"residentBindings": bindings.duplicate(true),
		"connectedResidents": _resident_names(identities),
		"worldStartMode": "formal",
		"capabilityMode": "formal",
		"source": "runtime",
		"formalReady": true,
		"providerFormalReady": true,
		"internalPlaytest": false,
		"internalLivePlaytest": false,
		"requireAgentGateway": true,
		"useLiveModel": true,
		"enablePlayerAvatar": false,
		"avatarInitialMode": "observer",
		"enableTestUi": false,
	}
	_expect_ok(
		restored_runtime.call("configure_session", restored_session_config) as Dictionary,
		"正式继续游戏配置可在小镇入树前完成",
	)
	_expect_equal(
		restored_runtime.call("_viewport_size_or_default"),
		Vector2(1920.0, 1080.0),
		"小镇入树前使用项目逻辑分辨率，不访问未挂载视口",
	)
	root.add_child(restored_runtime)
	await _wait_frames(5)
	_expect_ok(
		restored_runtime.call("get_startup_result") as Dictionary,
		"恢复中的正式小镇完成场景挂载",
	)
	var restored_world: RefCounted = restored_runtime.call("get_world_runtime")
	var restored_agent: RefCounted = restore_gateway.call("get_agent_save_participant")
	var restore_gate: RefCounted = RUNTIME_GATE.new()
	_expect_ok(
		restore_gate.call("configure", restored_runtime) as Dictionary,
		"恢复小镇事务锁可配置",
	)
	var restore_coordinator: RefCounted = COORDINATOR.new()
	_expect_ok(restore_coordinator.call(
		"configure",
		store,
		restored_world,
		restored_agent,
		restore_gate,
	) as Dictionary, "成对恢复协调器可配置")
	var restored := restore_coordinator.call(
		"restore_revision",
		slot_id,
		session_id,
		1,
		world_data,
		identities,
		restore_gateway,
	) as Dictionary
	_expect_ok(restored, "同一修订的世界与居民状态完整恢复")
	_expect_equal(restored.get("context"), context, "恢复回执对应所选存档修订")
	_expect_equal(restored_world.call("get_time"), saved_time, "恢复后世界时间与保存时一致")
	_expect_equal(
		restore_gateway.call("get_agent_save_context"),
		context,
		"恢复后居民存档上下文与世界修订一致",
	)
	var restored_experiment := restore_gateway.call(
		"get_runtime_observation_audit",
		String(u0_audit.get("observationId", "")),
	) as Dictionary
	_expect_equal(
		restored_experiment.get("rootMemoryId"),
		u0_audit.get("rootMemoryId"),
		"恢复后 U0 仍指向同一根记忆节点",
	)
	_expect_equal(
		(restored_experiment.get("rawText")),
		u0_audit.get("rawText"),
		"恢复后 U0 原始证据未被摘要覆盖",
	)
	_expect_equal(
		(restored_runtime.call("get_runtime_state") as Dictionary).get("avatarMode"),
		"observer",
		"加载存档后始终从自由观察模式进入小镇",
	)
	_expect_ok(
		restored_runtime.call("complete_restored_session", context) as Dictionary,
		"恢复完成状态可提交给小镇运行时",
	)
	_expect_equal(
		(restored_runtime.call("get_runtime_state") as Dictionary).get("viewMode"),
		"town",
		"恢复完成后正式小镇保持可见室外视图",
	)
	var next_global_intention := "下一版共同意图：诊所先分诊，再按轻重缓急安排照料。"
	var continuation := restore_gateway.call(
		"stage_global_intent_after_restore",
		{
			"text": next_global_intention,
			"sessionId": session_id,
			"sourceSaveRevision": 1,
		},
	) as Dictionary
	_expect_ok(continuation, "恢复后可在同一小镇建立下一版共同意图")
	_expect_equal(
		((continuation.get("version", {}) as Dictionary).get(
			"deliveries",
		[]) as Array).size(),
		identities.size(),
		"下一版共同意图一次覆盖全部居民",
	)
	var continued_experiment := restore_gateway.call(
		"capture_experiment_state",
	) as Dictionary
	_expect_ok(continued_experiment, "下一版共同意图可进入联合存档")
	var continued_session_config := session_config.duplicate(true)
	continued_session_config["mode"] = "continue"
	continued_session_config["experimentState"] = (
		continued_experiment.get("experimentState", {}) as Dictionary
	).duplicate(true)
	var continued_save := restore_coordinator.call("save", {
		"slotId": slot_id,
		"sessionId": session_id,
		"residentIdentities": identities.duplicate(true),
		"sessionConfig": continued_session_config,
		"savedAt": Time.get_datetime_string_from_system(false, false),
		"residentMessages": [],
	}) as Dictionary
	_expect_ok(continued_save, "下一版共同意图先形成新的完整存档修订")
	var continued_context := continued_save.get("context", {}) as Dictionary
	_expect_equal(
		continued_context.get("save_revision"),
		2,
		"U0@v1 建立明确的新修订边界",
	)
	_expect_ok(
		restore_gateway.call("dispatch_pending_global_intent") as Dictionary,
		"新修订发布后再唤醒居民处理共同意图",
	)
	var latest_continued := restore_coordinator.call(
		"discover_latest",
		slot_id,
	) as Dictionary
	_expect_ok(latest_continued, "U0@v1 修订成为该小镇的最新存档")
	_expect_equal(
		(latest_continued.get("summary", {}) as Dictionary).get("saveRevision"),
		2,
		"重新加载时会从 U0@v1 的存档边界继续",
	)

	var cleanup_agent := restored_agent
	restored_runtime.queue_free()
	await _wait_frames(4)
	_expect_ok(
		cleanup_agent.call("delete_game", continued_context) as Dictionary,
		"闭环测试居民存档可清理",
	)
	_expect_ok(store.call("cleanup_test_root") as Dictionary, "闭环测试世界存档可清理")
	request_host.queue_free()
	_finish()


func _identities(bindings: Array[Dictionary]) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for binding: Dictionary in bindings:
		result.append({
			"residentId": String(binding.get("residentId", "")),
			"residentName": String(binding.get("residentName", "")),
		})
	return result


func _saved_bindings(bindings: Array[Dictionary]) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for binding: Dictionary in bindings:
		var llm := binding.get("llmBinding", {}) as Dictionary
		result.append({
			"residentId": String(binding.get("residentId", "")),
			"llmBinding": {
				"mode": String(llm.get("mode", "")),
				"providerId": String(llm.get("providerId", "")),
				"modelId": String(llm.get("modelId", "")),
			},
		})
	return result


func _resident_names(identities: Array[Dictionary]) -> Array[String]:
	var result: Array[String] = []
	for identity: Dictionary in identities:
		result.append(String(identity.get("residentName", "")))
	return result


func _read_json(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {}
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	file = null
	return parsed as Dictionary if parsed is Dictionary else {}


func _wait_frames(count: int) -> void:
	for _index in count:
		await process_frame


func _wait_for_u0_root_mapping(gateway: Node) -> Dictionary:
	for _index in 240:
		var audit := gateway.call("get_runtime_observation_audit") as Dictionary
		for record_value: Variant in audit.get("records", []) as Array:
			var record := record_value as Dictionary
			if (
				String(record.get("kind", "")) == "U0"
				and not String(record.get("rootMemoryId", "")).is_empty()
			):
				return record.duplicate(true)
		await process_frame
	return {}


func _expect_ok(result: Dictionary, message: String) -> void:
	_expect(
		bool(result.get("ok", false)),
		"%s（%s）" % [message, result.get("errorCode", "")],
	)


func _expect_equal(actual: Variant, expected: Variant, message: String) -> void:
	_expect(actual == expected, "%s；实际=%s，预期=%s" % [message, actual, expected])


func _expect(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures.append(message)


func _finish() -> void:
	var audio := root.get_node_or_null("TownAudioController")
	if audio != null and audio.has_method("prepare_shutdown"):
		audio.call("prepare_shutdown")
	for _index in 5:
		await process_frame
	await create_timer(0.3, true, false, true).timeout
	if _failures.is_empty():
		print("SESSION_SAVE_CONTINUE_ROUNDTRIP_PASS checks=%d" % _checks)
		quit(0)
		return
	for failure: String in _failures:
		printerr("SESSION_SAVE_CONTINUE_ROUNDTRIP_FAIL: %s" % failure)
	quit(1)
