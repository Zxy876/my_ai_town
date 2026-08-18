extends "res://tests/support/TownWorldTestCase.gd"


const RESIDENT_ID := "resident_su_he_01"


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var data := _build_data()
	var opening := _load_opening(data)
	var world: RefCounted = WORLD.new()
	_expect_equal(
		(world.call("start", data, opening) as Dictionary).get("ok"),
		true,
		"runtime observation world starts",
	)
	var initial_requests := world.call(
		"take_pending_decision_requests_by_ids",
		[RESIDENT_ID],
	) as Array
	_expect_equal(initial_requests.size(), 1, "target resident receives initial decision")
	if initial_requests.is_empty():
		world.call("stop")
		_finish_suite("TOWN_RUNTIME_OBSERVATION_WAKE_PASS")
		return
	var initial_wake := (
		(initial_requests[0] as Dictionary).get("wakePacket", {}) as Dictionary
	)
	var start_action := world.call("submit_agent_decision_by_id", RESIDENT_ID, {
		"decision_id": String(initial_wake.get("decision_id", "")),
		"handling": "replace_current",
		"action": {
			"action_id": "runtime-observation-current-action",
			"type": "待着",
			"line": "继续整理手边的书。",
		},
	}) as Dictionary
	_expect_equal(start_action.get("status"), "accepted", "resident starts an ordinary action")
	var before := world.call("get_resident_state", RESIDENT_ID) as Dictionary
	var wake_request := world.call(
		"request_runtime_observation_wake",
		RESIDENT_ID,
	) as Dictionary
	_expect_equal(wake_request.get("ok"), true, "world accepts a cognitive wake request")
	_expect_equal(
		wake_request.get("scheduled"),
		true,
		"observation can create a decision opportunity during an action",
	)
	var during := world.call("get_resident_state", RESIDENT_ID) as Dictionary
	_expect_equal(
		during.get("position"),
		before.get("position"),
		"requesting observation cognition does not move the resident",
	)
	_expect_equal(
		during.get("currentAction"),
		before.get("currentAction"),
		"requesting observation cognition does not cancel the current action",
	)
	var observation_requests := world.call(
		"take_pending_decision_requests_by_ids",
		[RESIDENT_ID],
	) as Array
	_expect_equal(observation_requests.size(), 1, "world exposes one observation decision opportunity")
	if observation_requests.size() == 1:
		var wake := (
			(observation_requests[0] as Dictionary).get("wakePacket", {}) as Dictionary
		)
		_expect_equal(
			((wake.get("snapshot", {}) as Dictionary)
				.get("me", {}) as Dictionary)
				.get("current_action", {})
				.get("action_id"),
			"runtime-observation-current-action",
			"observation wake presents the unchanged current action",
		)
		var continued := world.call("submit_agent_decision_by_id", RESIDENT_ID, {
			"decision_id": String(wake.get("decision_id", "")),
			"handling": "continue_current",
		}) as Dictionary
		_expect_equal(
			continued.get("status"),
			"continued",
			"resident remains free to continue the current action",
		)
	world.call("stop")
	_finish_suite("TOWN_RUNTIME_OBSERVATION_WAKE_PASS")
