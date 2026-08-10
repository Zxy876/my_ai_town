extends "res://tests/agent/support/AgentTestCase.gd"


const EXPERIMENT := preload(
	"res://world/integration/TownExperimentScenarioState.gd"
)
const TestData := preload("res://tests/support/AgentMemoryTestData.gd")


func _initialize() -> void:
	var residents: Array[String] = ["resident-lin-lan"]
	var definition := {
		"scenarioId": "hospital-intention-v1",
		"episodeId": "common-root",
		"u0Observations": [{
			"targetResidentId": "resident-lin-lan",
			"text": "我建立诊所，是为了让每个临时来访者都能及时得到照料。",
		}],
	}
	var experiment: RefCounted = EXPERIMENT.new()
	var global_host := root.get_node_or_null("GameFlowHost")
	_expect(global_host != null, "Scenario setup is owned by the global game-flow host")
	if global_host != null:
		global_host.call("clear_experiment_scenario")
		_expect_ok(
			global_host.call("configure_experiment_scenario", definition),
			"global setup can stage U0 before world initialization",
		)
		_expect_equal(
			(global_host.call("get_staged_experiment_scenario") as Dictionary)
				.get("scenarioId"),
			"hospital-intention-v1",
			"global setup retains Scenario identity for bootstrap",
		)
		_expect_ok(
			global_host.call("clear_experiment_scenario"),
			"global setup can be cleared before a world starts",
		)
	_expect_ok(
		experiment.call("configure_new_session", definition, residents),
		"U0 is configured as a pre-runtime Scenario condition",
	)
	var runtime_u0 := experiment.call("enqueue", {
		"targetResidentId": "resident-lin-lan",
		"kind": "U0",
		"text": "a late initial intention",
	}, residents) as Dictionary
	_expect_equal(
		runtime_u0.get("errorCode"),
		"U0_INITIALIZATION_ONLY",
		"runtime entry cannot create or overwrite U0",
	)
	_expect_ok(experiment.call("enqueue", {
		"observationId": "runtime-u-minus-after-start",
		"targetResidentId": "resident-lin-lan",
		"kind": "U-",
		"text": "候诊者被安排继续等待。",
	}, residents), "runtime U- still uses the observation transport")
	_expect_ok(
		experiment.call(
			"activate_initial_conditions",
			residents,
			{"day": 1, "hour": 8, "minute": 0},
		),
		"Scenario activation stages U0 before cognition",
	)
	var duplicate_activation := experiment.call(
		"activate_initial_conditions",
		residents,
		{"day": 1, "hour": 8, "minute": 0},
	) as Dictionary
	_expect_equal(
		duplicate_activation.get("changed"),
		false,
		"replaying Scenario activation is idempotent",
	)
	var audit := experiment.call("audit_snapshot") as Dictionary
	var scenario := audit.get("scenario", {}) as Dictionary
	var staged := scenario.get("u0Observations", []) as Array
	_expect_equal(scenario.get("status"), "activated", "Scenario activation is explicit")
	_expect_equal(staged.size(), 1, "Scenario retains one canonical U0 definition")
	var u0_id := String((staged[0] as Dictionary).get("observationId", ""))
	_expect(u0_id.begins_with("scenario-u0-"), "U0 receives a stable Scenario-root id")
	var attached := experiment.call(
		"attach_to_wake",
		"resident-lin-lan",
		"first-cognitive-step",
		TestData.wake_packet("first-cognitive-step"),
	) as Dictionary
	_expect_ok(attached, "first cognitive step receives staged initial conditions")
	var payloads := (
		attached.get("wakePacket", {}) as Dictionary
	).get("runtime_observations", []) as Array
	_expect_equal(payloads.size(), 2, "U0 and runtime evidence may share transport without sharing entry semantics")
	for payload_value: Variant in payloads:
		_expect_equal(
			(payload_value as Dictionary).keys(),
			["observation_id", "text"],
			"Agent sees facts rather than experiment labels",
		)
	var stored := experiment.call("mark_stored", "first-cognitive-step") as Array
	_expect_equal(stored.size(), 2, "accepted cognition stores every attached observation")
	_expect_ok(experiment.call("mark_root_memory", u0_id, {
		"memoryId": "memory-u0-root",
		"claimRootId": "runtime_observation:%s" % u0_id,
	}), "U0 audit links to the actual first-order memory root")
	experiment.call("mark_result", "first-cognitive-step", true)
	_expect_ok(
		experiment.call("mark_outcome", u0_id, "adopted"),
		"U0 adoption remains an explicit evaluation",
	)
	var u0_audit := experiment.call("audit_snapshot", u0_id) as Dictionary
	_expect_equal(u0_audit.get("rootMemoryId"), "memory-u0-root", "root memory mapping is queryable")
	_expect_equal(u0_audit.get("perceived"), true, "U0 perception is distinct from configuration")

	var capture := experiment.call("capture_state") as Dictionary
	_expect_ok(capture, "Scenario and transport capture as one experiment state")
	var restored: RefCounted = EXPERIMENT.new()
	_expect_ok(restored.call(
		"apply_state",
		capture.get("experimentState"),
		residents,
	), "experiment state restores through the save boundary")
	var restored_audit := restored.call("audit_snapshot", u0_id) as Dictionary
	_expect_equal(restored_audit.get("rootMemoryId"), "memory-u0-root", "restore preserves U0 to memory mapping")
	_expect_equal(
		(restored.call("audit_snapshot") as Dictionary).get("scenario"),
		scenario,
		"restore preserves Scenario and Episode identity",
	)

	var pending: RefCounted = EXPERIMENT.new()
	_expect_ok(pending.call("configure_new_session", definition, residents), "second branch stages the same U0")
	_expect_ok(pending.call(
		"activate_initial_conditions",
		residents,
		{"day": 1, "hour": 8, "minute": 0},
	), "second branch activates U0")
	pending.call(
		"attach_to_wake",
		"resident-lin-lan",
		"interrupted-step",
		TestData.wake_packet("interrupted-step"),
	)
	var pending_capture := pending.call("capture_state") as Dictionary
	var resumed: RefCounted = EXPERIMENT.new()
	_expect_ok(resumed.call(
		"apply_state",
		pending_capture.get("experimentState"),
		residents,
	), "an interrupted pre-storage delivery restores safely")
	var resumed_attachment := resumed.call(
		"attach_to_wake",
		"resident-lin-lan",
		"resumed-step",
		TestData.wake_packet("resumed-step"),
	) as Dictionary
	_expect_equal(
		((resumed_attachment.get("wakePacket", {}) as Dictionary)
			.get("runtime_observations", []) as Array).size(),
		1,
		"unfinished U0 delivery returns to the committed boundary once",
	)
	_finish_suite("EXPERIMENT_SCENARIO_STATE_PASS")
