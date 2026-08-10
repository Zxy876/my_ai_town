extends "res://tests/agent/support/AgentTestCase.gd"


const ADAPTER := preload(
	"res://world/integration/TownRuntimeObservationAdapter.gd"
)
const TestData := preload("res://tests/support/AgentMemoryTestData.gd")


func _initialize() -> void:
	var adapter: RefCounted = ADAPTER.new()
	var valid_residents: Array[String] = [
		"resident-lin-lan",
		"resident-tang-xiao-man",
	]
	var raw_text := "诊所候诊区已经有两个人等了很久。\n请留意。"
	var request := {
		"observationId": "manual-u0-1",
		"targetResidentId": "resident-lin-lan",
		"kind": "U0",
		"text": raw_text,
	}
	var first := adapter.call("enqueue", request, valid_residents) as Dictionary
	var duplicate := adapter.call("enqueue", request, valid_residents) as Dictionary
	_expect_ok(first, "runtime observation commits to the adapter")
	_expect_equal(duplicate.get("duplicate"), true, "same observation id is idempotent")
	var conflict := request.duplicate(true)
	conflict["text"] = "不同内容"
	_expect_equal(
		(adapter.call("enqueue", conflict, valid_residents) as Dictionary).get("ok"),
		false,
		"same observation id rejects different content",
	)
	var wrong_target := request.duplicate(true)
	wrong_target["observationId"] = "manual-u0-wrong-target"
	wrong_target["targetResidentId"] = "resident-missing"
	_expect_equal(
		(adapter.call("enqueue", wrong_target, valid_residents) as Dictionary).get("ok"),
		false,
		"observation cannot target an unknown resident",
	)
	var wake := TestData.wake_packet("runtime-observation-decision-1")
	var unrelated := adapter.call(
		"attach_to_wake",
		"resident-tang-xiao-man",
		"unrelated-decision",
		wake,
	) as Dictionary
	_expect(
		not (unrelated.get("wakePacket", {}) as Dictionary).has(
			"runtime_observations",
		),
		"runtime observation stays isolated to its target resident",
	)
	var unclassified := adapter.call("enqueue", {
		"observationId": "manual-unclassified-1",
		"targetResidentId": "resident-tang-xiao-man",
		"text": "门口的雨越下越大。",
	}, valid_residents) as Dictionary
	_expect_ok(unclassified, "manual entry does not require a U classification")
	_expect_equal(
		(unclassified.get("observation", {}) as Dictionary).get("kind"),
		"",
		"unclassified manual input is not silently labeled U0",
	)
	var attached := adapter.call(
		"attach_to_wake",
		"resident-lin-lan",
		"runtime-observation-decision-1",
		wake,
	) as Dictionary
	_expect_ok(attached, "target resident receives the committed observation")
	var attached_wake := attached.get("wakePacket", {}) as Dictionary
	var payloads := attached_wake.get("runtime_observations", []) as Array
	_expect_equal(payloads.size(), 1, "one committed observation is attached once")
	if payloads.size() == 1:
		var payload := payloads[0] as Dictionary
		_expect_equal(
			payload.keys(),
			["observation_id", "text"],
			"agent payload excludes U kind and audit metadata",
		)
		_expect_equal(payload.get("text"), raw_text, "agent payload preserves raw text")
	adapter.call("mark_stored", "runtime-observation-decision-1")
	var stored := adapter.call("audit_snapshot", "manual-u0-1") as Dictionary
	_expect_equal(stored.get("stored"), true, "accepted wake records evidence storage")
	var next_wake := adapter.call(
		"attach_to_wake",
		"resident-lin-lan",
		"runtime-observation-decision-2",
		TestData.wake_packet("runtime-observation-decision-2"),
	) as Dictionary
	_expect(
		not (next_wake.get("wakePacket", {}) as Dictionary).has(
			"runtime_observations",
		),
		"stored observation is not rendered in a later decision",
	)
	adapter.call("mark_result", "runtime-observation-decision-1", true)
	var perceived := adapter.call("audit_snapshot", "manual-u0-1") as Dictionary
	_expect_equal(perceived.get("perceived"), true, "valid model result records perception")
	_expect_equal(
		perceived.get("actualDecisionId"),
		"runtime-observation-decision-1",
		"audit records the actual cognitive step",
	)
	var recovered_request := {
		"observationId": "manual-recovered-result",
		"targetResidentId": "resident-lin-lan",
		"text": "第一次模型回复无效，但重试后居民完成了这次认知。",
	}
	_expect_ok(
		adapter.call("enqueue", recovered_request, valid_residents),
		"recovered-result fixture can enqueue",
	)
	adapter.call(
		"attach_to_wake",
		"resident-lin-lan",
		"runtime-observation-recovered-result",
		TestData.wake_packet("runtime-observation-recovered-result"),
	)
	adapter.call("mark_stored", "runtime-observation-recovered-result")
	adapter.call(
		"mark_result",
		"runtime-observation-recovered-result",
		false,
		"AGENT_DECISION_REQUEST_FAILED",
	)
	adapter.call("mark_result", "runtime-observation-recovered-result", true)
	var recovered_audit := adapter.call(
		"audit_snapshot",
		"manual-recovered-result",
	) as Dictionary
	_expect_equal(
		recovered_audit.get("perceived"),
		true,
		"a later successful cognition recovers the observation audit",
	)
	_expect_equal(
		recovered_audit.get("failed"),
		false,
		"a recovered observation no longer remains falsely failed",
	)
	_expect_equal(
		recovered_audit.get("failureCode"),
		"",
		"a recovered observation clears the stale failure code",
	)
	_expect_ok(
		adapter.call("mark_outcome", "manual-u0-1", "not_adopted"),
		"manual evaluation can mark non-adoption",
	)
	var evaluated := adapter.call("audit_snapshot", "manual-u0-1") as Dictionary
	_expect_equal(evaluated.get("ineffective"), true, "non-adoption is tracked as ineffective")

	var retry_request := {
		"observationId": "manual-u-plus-retry",
		"targetResidentId": "resident-lin-lan",
		"kind": "U+",
		"text": "刚才的排队安排让等待时间缩短了。",
	}
	_expect_ok(
		adapter.call("enqueue", retry_request, valid_residents),
		"U+ uses the same adapter path",
	)
	adapter.call(
		"attach_to_wake",
		"resident-lin-lan",
		"runtime-observation-retry",
		TestData.wake_packet("runtime-observation-retry"),
	)
	adapter.call("release_dispatch", "runtime-observation-retry")
	var retried := adapter.call(
		"attach_to_wake",
		"resident-lin-lan",
		"runtime-observation-retry",
		TestData.wake_packet("runtime-observation-retry"),
	) as Dictionary
	_expect_equal(
		(retried.get("wakePacket", {}) as Dictionary)
			.get("runtime_observations", []).size(),
		1,
		"pre-cognition rejection releases the observation for one retry",
	)
	adapter.call("mark_failed", "manual-u-plus-retry", "TEST_TERMINAL")
	for index in 513:
		var audit_id := "audit-prune-%03d" % index
		_expect_ok(adapter.call("enqueue", {
			"observationId": audit_id,
			"targetResidentId": "resident-lin-lan",
			"text": "普通运行时观察 %d" % index,
		}, valid_residents), "audit pruning fixture can enqueue")
		adapter.call("mark_failed", audit_id, "TEST_TERMINAL")
	_expect(
		not (adapter.call("audit_snapshot", "manual-u0-1") as Dictionary).is_empty(),
		"U0 raw audit survives bounded runtime audit pruning",
	)
	_finish_suite("RUNTIME_OBSERVATION_ADAPTER_PASS")
