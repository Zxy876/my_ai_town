extends SceneTree


const RUNTIME_GATE := preload(
	"res://world/presentation/session/TownSessionRuntimeGate.gd"
)

var _failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var runtime := Node.new()
	runtime.set_process(true)
	runtime.set_physics_process(true)
	runtime.set_process_input(true)
	runtime.set_process_unhandled_input(true)
	var gate: RefCounted = RUNTIME_GATE.new()
	_expect_ok(
		gate.call("configure", runtime) as Dictionary,
		"事务门可绑定运行时节点",
	)
	var begun := gate.call("begin_session_transaction", "save", {}) as Dictionary
	_expect_ok(begun, "事务门可开始会话事务")
	_expect_equal(
		runtime.is_processing_input(),
		false,
		"事务进行中会禁用输入处理",
	)
	_expect_equal(
		runtime.is_processing_unhandled_input(),
		false,
		"事务进行中会禁用未处理输入",
	)
	var ended_with_stale := gate.call(
		"end_session_transaction",
		"stale-token",
	) as Dictionary
	_expect_equal(
		ended_with_stale.get("ok"),
		false,
		"陈旧 token 仍会返回失败",
	)
	_expect_equal(
		ended_with_stale.get("errorCode"),
		"SESSION_SAVE_GATE_STALE",
		"陈旧 token 返回固定错误码",
	)
	_expect_equal(
		runtime.is_processing_input(),
		true,
		"陈旧 token 结束事务后仍会恢复输入处理",
	)
	_expect_equal(
		runtime.is_processing_unhandled_input(),
		true,
		"陈旧 token 结束事务后仍会恢复未处理输入",
	)
	_expect_ok(
		gate.call("begin_session_transaction", "save", {}) as Dictionary,
		"陈旧 token 清理后仍可重新开始事务",
	)
	runtime.free()
	_finish()


func _expect_ok(result: Dictionary, label: String) -> void:
	if result.get("ok") == true:
		return
	_failures.append(
		"%s (errorCode=%s)" % [label, String(result.get("errorCode", ""))],
	)


func _expect_equal(actual: Variant, expected: Variant, label: String) -> void:
	if actual == expected:
		return
	_failures.append("%s (actual=%s expected=%s)" % [label, actual, expected])


func _finish() -> void:
	var exit_code := 0 if _failures.is_empty() else 1
	if _failures.is_empty():
		print("TOWN_SESSION_RUNTIME_GATE_PASS")
	else:
		printerr("TOWN_SESSION_RUNTIME_GATE_FAIL: %s" % "; ".join(_failures))
	var audio_controller := root.get_node_or_null("TownAudioController")
	if audio_controller != null and audio_controller.has_method("prepare_shutdown"):
		audio_controller.call("prepare_shutdown")
	for _index in 5:
		await process_frame
	await create_timer(0.3, true, false, true).timeout
	quit(exit_code)
