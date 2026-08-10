extends "res://tests/agent/support/AgentTestCase.gd"


const GATEWAY := preload(
	"res://world/integration/TownWorldAgentGateway.gd"
)
const TestData := preload("res://tests/support/AgentMemoryTestData.gd")


class RecordingWorld:
	extends RefCounted

	var wake: Dictionary = {}
	var wake_requests: Array[String] = []
	var fail_wake_request := false

	func get_time() -> Dictionary:
		return {"day": 2, "clock": "10:20", "period": "上午"}

	func request_runtime_observation_wake(resident_id: String) -> Dictionary:
		wake_requests.append(resident_id)
		if fail_wake_request:
			return {
				"ok": false,
				"errorCode": "RUNTIME_OBSERVATION_TARGET_UNAVAILABLE",
				"retryable": false,
			}
		return {"ok": true, "scheduled": true}

	func refresh_pending_decision_request_by_id(
		resident_id: String,
		decision_id: String,
	) -> Dictionary:
		return {
			"ok": true,
			"residentId": resident_id,
			"decisionId": decision_id,
			"wakePacket": wake.duplicate(true),
		}

	func redispatch_decision_request_by_id(
		_resident_id: String,
		_decision_id: String,
	) -> bool:
		return true

	func submit_agent_decision_by_id(
		_resident_id: String,
		_decision: Dictionary,
	) -> Dictionary:
		return {"ok": true, "status": "continued"}


class RecordingAgent:
	extends RefCounted

	var received_wake: Dictionary = {}
	var completion: Callable

	func request_decision(
		_resident_id: String,
		wake_packet: Dictionary,
		_on_complete: Callable,
	) -> Dictionary:
		received_wake = wake_packet.duplicate(true)
		completion = _on_complete
		return {"ok": true, "decision_id": wake_packet.get("decision_id", "")}

	func complete(result: Dictionary) -> void:
		completion.call(result)


func _initialize() -> void:
	var gateway: Node = GATEWAY.new()
	root.add_child(gateway)
	var world := RecordingWorld.new()
	world.wake = TestData.wake_packet("runtime-observation-gateway-1")
	var agent := RecordingAgent.new()
	gateway.set("_world", world)
	gateway.set("_agent_system", agent)
	gateway.set("_session_active", true)
	var connected_residents: Array[String] = ["resident-lin-lan"]
	gateway.set("_connected_resident_ids", connected_residents)
	var queued := gateway.call("queue_runtime_observation", {
		"observationId": "gateway-u-minus-1",
		"targetResidentId": "resident-lin-lan",
		"kind": "U-",
		"text": "也有人在无人引导时顺利完成了挂号。",
	}) as Dictionary
	_expect_ok(queued, "gateway accepts a targeted runtime observation")
	_expect_equal(
		world.wake_requests,
		["resident-lin-lan"],
		"gateway requests a non-forcing cognitive opportunity",
	)
	gateway.call("_request_agent_decision", {
		"residentId": "resident-lin-lan",
		"residentName": "林岚",
		"wakePacket": world.wake.duplicate(true),
	})
	var observations := agent.received_wake.get("runtime_observations", []) as Array
	_expect_equal(observations.size(), 1, "gateway attaches observation after final world refresh")
	if observations.size() == 1:
		_expect_equal(
			(observations[0] as Dictionary).get("text"),
			"也有人在无人引导时顺利完成了挂号。",
			"agent receives the exact ordinary observation text",
		)
		_expect(
			not (observations[0] as Dictionary).has("kind"),
			"agent does not receive the U- control label",
		)
	var received_base := agent.received_wake.duplicate(true)
	received_base.erase("runtime_observations")
	_expect_equal(
		received_base,
		world.wake,
		"gateway changes no plan, memory, position, or world input before perception",
	)
	var audit := gateway.call(
		"get_runtime_observation_audit",
		"gateway-u-minus-1",
	) as Dictionary
	_expect_equal(audit.get("stored"), true, "accepted agent request records stored evidence")
	_expect_equal(
		audit.get("actualDecisionId"),
		"runtime-observation-gateway-1",
		"gateway audit records the exact decision step",
	)
	agent.complete({
		"ok": true,
		"decision": {
			"decision_id": "runtime-observation-gateway-1",
			"handling": "continue_current",
		},
	})
	audit = gateway.call(
		"get_runtime_observation_audit",
		"gateway-u-minus-1",
	) as Dictionary
	_expect_equal(audit.get("perceived"), true, "completed cognition records perception")
	var duplicate := gateway.call("queue_runtime_observation", {
		"observationId": "gateway-u-minus-1",
		"targetResidentId": "resident-lin-lan",
		"kind": "U-",
		"text": "也有人在无人引导时顺利完成了挂号。",
	}) as Dictionary
	_expect_equal(duplicate.get("duplicate"), true, "stored duplicate is idempotent")
	_expect_equal(
		world.wake_requests.size(),
		1,
		"stored duplicate does not create an empty cognitive wake",
	)
	world.fail_wake_request = true
	var unavailable := gateway.call("queue_runtime_observation", {
		"observationId": "gateway-unavailable-1",
		"targetResidentId": "resident-lin-lan",
		"text": "诊所门口已经排起长队。",
	}) as Dictionary
	_expect_equal(unavailable.get("ok"), false, "wake failure is returned to the caller")
	var failed_audit := gateway.call(
		"get_runtime_observation_audit",
		"gateway-unavailable-1",
	) as Dictionary
	_expect_equal(failed_audit.get("failed"), true, "wake failure remains auditable")
	_expect_equal(
		failed_audit.get("failureCode"),
		"RUNTIME_OBSERVATION_TARGET_UNAVAILABLE",
		"audit preserves the world failure reason",
	)

	var initial_gateway: Node = GATEWAY.new()
	root.add_child(initial_gateway)
	var initial_world := RecordingWorld.new()
	initial_world.fail_wake_request = true
	initial_world.wake = TestData.wake_packet("initial-intention-first-cognition")
	var initial_agent := RecordingAgent.new()
	initial_gateway.set("_world", initial_world)
	initial_gateway.set("_agent_system", initial_agent)
	initial_gateway.set("_connected_resident_ids", connected_residents)
	var initial_observations: RefCounted = initial_gateway.get("_runtime_observations")
	_expect_ok(initial_observations.call("configure_new_session", {
		"scenarioId": "party-intention-before-arrival",
		"episodeId": "common-root",
		"u0Observations": [{
			"targetResidentId": "resident-lin-lan",
			"text": "林岚和唐小满打算共同举办派对。",
		}],
	}, connected_residents), "initial intention is staged before arrival")
	var initial_activation := initial_gateway.call(
		"_activate_initial_experiment_conditions",
	) as Dictionary
	_expect_ok(
		initial_activation,
		"an absent new-game resident defers U0 instead of failing startup",
	)
	var initial_audit := initial_gateway.call(
		"get_runtime_observation_audit",
	) as Dictionary
	var initial_items := initial_audit.get("records", []) as Array
	_expect_equal(initial_items.size(), 1, "deferred U0 remains queued")
	if initial_items.size() == 1:
		_expect_equal(
			(initial_items[0] as Dictionary).get("failed"),
			false,
			"absence before arrival does not poison U0",
		)
	initial_gateway.set("_session_active", true)
	initial_world.fail_wake_request = false
	initial_gateway.call("_request_pending_runtime_observation_wakes")
	initial_gateway.call("_request_agent_decision", {
		"residentId": "resident-lin-lan",
		"residentName": "林岚",
		"wakePacket": initial_world.wake.duplicate(true),
	})
	var initial_payloads := (
		initial_agent.received_wake.get("runtime_observations", []) as Array
	)
	_expect_equal(
		initial_payloads.size(),
		1,
		"the resident's first available cognition receives deferred U0",
	)
	if initial_payloads.size() == 1:
		_expect_equal(
			(initial_payloads[0] as Dictionary).get("text"),
			"林岚和唐小满打算共同举办派对。",
			"first cognition receives the player's exact initial intention",
		)
	initial_gateway.queue_free()
	gateway.queue_free()
	_finish_suite("RUNTIME_OBSERVATION_GATEWAY_PASS")
