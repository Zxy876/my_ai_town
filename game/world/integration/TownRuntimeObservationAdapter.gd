class_name TownRuntimeObservationAdapter
extends RefCounted


const KINDS: Array[String] = ["U0", "U+", "U-"]
const OUTCOMES: Array[String] = [
	"pending", "adopted", "not_adopted", "effective", "ineffective",
]
const MAX_TEXT_CHARS := 2000
const MAX_PENDING_PER_RESIDENT := 32
const MAX_AUDIT_RECORDS := 512
const STATE_VERSION := 1
const RECORD_STATUSES: Array[String] = [
	"committed", "injected", "stored", "perceived", "failed", "ineffective",
]

var _records_by_id: Dictionary = {}
var _record_order: Array[String] = []
var _pending_by_resident: Dictionary = {}
var _observation_ids_by_decision: Dictionary = {}
var _sequence := 0


func reset() -> void:
	_records_by_id.clear()
	_record_order.clear()
	_pending_by_resident.clear()
	_observation_ids_by_decision.clear()
	_sequence = 0


func enqueue(request: Dictionary, valid_resident_ids: Array[String]) -> Dictionary:
	var resident_id := String(
		request.get("targetResidentId", request.get("target_resident_id", "")),
	).strip_edges()
	var kind_result := _normalize_kind(
		String(request.get("kind", request.get("uKind", ""))),
	)
	var kind := String(kind_result.get("kind", ""))
	var raw_text := String(request.get("text", request.get("rawText", "")))
	var observation_id := String(
		request.get("observationId", request.get("observation_id", "")),
	).strip_edges()
	if resident_id.is_empty() or not valid_resident_ids.has(resident_id):
		return _failure("RUNTIME_OBSERVATION_TARGET_INVALID")
	if not bool(kind_result.get("ok", false)):
		return _failure("RUNTIME_OBSERVATION_KIND_INVALID")
	if raw_text.strip_edges().is_empty() or raw_text.length() > MAX_TEXT_CHARS:
		return _failure("RUNTIME_OBSERVATION_TEXT_INVALID")
	if observation_id.is_empty():
		_sequence += 1
		observation_id = "runtime-observation-%d-%06d" % [
			int(Time.get_unix_time_from_system() * 1000000.0),
			_sequence,
		]
	if not _id_is_safe(observation_id):
		return _failure("RUNTIME_OBSERVATION_ID_INVALID")
	if _records_by_id.has(observation_id):
		var existing := _records_by_id[observation_id] as Dictionary
		if (
			String(existing.get("targetResidentId", "")) == resident_id
			and String(existing.get("kind", "")) == kind
			and String(existing.get("rawText", "")) == raw_text
		):
			return {
				"ok": true,
				"duplicate": true,
				"observation": existing.duplicate(true),
			}
		return _failure("RUNTIME_OBSERVATION_ID_CONFLICT")
	var pending := _pending_for_resident(resident_id)
	if pending.size() >= MAX_PENDING_PER_RESIDENT:
		return _failure("RUNTIME_OBSERVATION_QUEUE_FULL")
	var record := {
		"observationId": observation_id,
		"targetResidentId": resident_id,
		"kind": kind,
		"rawText": raw_text,
		"status": "committed",
		"outcome": "pending",
		"committed": true,
		"stored": false,
		"perceived": false,
		"failed": false,
		"ineffective": false,
		"actualDecisionId": "",
		"dispatchAttempts": 0,
		"deliveryCount": 0,
		"createdAtMsec": Time.get_ticks_msec(),
		"updatedAtMsec": Time.get_ticks_msec(),
		"createdWorldTime": (
			(request.get("createdWorldTime", {}) as Dictionary).duplicate(true)
			if request.get("createdWorldTime") is Dictionary
			else {}
		),
		"failureCode": "",
		"rootMemoryId": "",
		"rootClaimId": "",
	}
	_records_by_id[observation_id] = record
	_record_order.append(observation_id)
	pending.append(observation_id)
	_pending_by_resident[resident_id] = pending
	_prune_audit()
	return {
		"ok": true,
		"duplicate": false,
		"observation": record.duplicate(true),
	}


func pending_resident_ids() -> Array[String]:
	var result: Array[String] = []
	for resident_id_value: Variant in _pending_by_resident:
		var resident_id := String(resident_id_value)
		if not _pending_for_resident(resident_id).is_empty():
			result.append(resident_id)
	result.sort()
	return result


func attach_to_wake(
	resident_id: String,
	decision_id: String,
	wake_packet: Dictionary,
) -> Dictionary:
	var normalized_resident := resident_id.strip_edges()
	var normalized_decision := decision_id.strip_edges()
	if normalized_resident.is_empty() or normalized_decision.is_empty():
		return _failure("RUNTIME_OBSERVATION_DISPATCH_INVALID")
	var ids: Array[String] = []
	if _observation_ids_by_decision.has(normalized_decision):
		ids.assign(_observation_ids_by_decision[normalized_decision])
	else:
		ids = _pending_for_resident(normalized_resident)
	if ids.is_empty():
		return {
			"ok": true,
			"wakePacket": wake_packet.duplicate(true),
			"observationIds": [],
		}
	var payloads: Array[Dictionary] = []
	for observation_id: String in ids:
		if not _records_by_id.has(observation_id):
			continue
		var record := _records_by_id[observation_id] as Dictionary
		if String(record.get("targetResidentId", "")) != normalized_resident:
			return _failure("RUNTIME_OBSERVATION_TARGET_MISMATCH")
		record["status"] = "injected"
		record["actualDecisionId"] = normalized_decision
		record["dispatchAttempts"] = int(record.get("dispatchAttempts", 0)) + 1
		record["updatedAtMsec"] = Time.get_ticks_msec()
		_records_by_id[observation_id] = record
		payloads.append({
			"observation_id": observation_id,
			"text": String(record.get("rawText", "")),
		})
	_observation_ids_by_decision[normalized_decision] = ids.duplicate()
	var wake := wake_packet.duplicate(true)
	wake["runtime_observations"] = payloads
	return {
		"ok": true,
		"wakePacket": wake,
		"observationIds": ids.duplicate(),
	}


func mark_stored(decision_id: String) -> Array[Dictionary]:
	var stored_records: Array[Dictionary] = []
	var normalized := decision_id.strip_edges()
	for observation_id: String in _decision_observation_ids(normalized):
		if not _records_by_id.has(observation_id):
			continue
		var record := _records_by_id[observation_id] as Dictionary
		record["stored"] = true
		record["status"] = (
			"perceived" if bool(record.get("perceived", false))
			else "failed" if bool(record.get("failed", false))
			else "stored"
		)
		record["deliveryCount"] = int(record.get("deliveryCount", 0)) + 1
		record["updatedAtMsec"] = Time.get_ticks_msec()
		_records_by_id[observation_id] = record
		_remove_pending(String(record.get("targetResidentId", "")), observation_id)
		stored_records.append(record.duplicate(true))
	_release_completed_decision(normalized)
	return stored_records


func mark_root_memory(observation_id: String, mapping: Dictionary) -> Dictionary:
	var normalized := observation_id.strip_edges()
	if not _records_by_id.has(normalized):
		return _failure("RUNTIME_OBSERVATION_NOT_FOUND")
	var memory_id := String(mapping.get("memoryId", "")).strip_edges()
	var claim_id := String(mapping.get("claimRootId", "")).strip_edges()
	if memory_id.is_empty() or claim_id.is_empty():
		return _failure("RUNTIME_OBSERVATION_MEMORY_MAPPING_INVALID")
	var expected_claim_id := "runtime_observation:%s" % normalized
	if claim_id != expected_claim_id:
		return _failure("RUNTIME_OBSERVATION_MEMORY_MAPPING_MISMATCH")
	var record := _records_by_id[normalized] as Dictionary
	record["rootMemoryId"] = memory_id
	record["rootClaimId"] = claim_id
	record["updatedAtMsec"] = Time.get_ticks_msec()
	_records_by_id[normalized] = record
	return {"ok": true, "observation": record.duplicate(true)}


func release_dispatch(decision_id: String) -> void:
	var normalized := decision_id.strip_edges()
	for observation_id: String in _decision_observation_ids(normalized):
		if not _records_by_id.has(observation_id):
			continue
		var record := _records_by_id[observation_id] as Dictionary
		if bool(record.get("stored", false)):
			continue
		record["status"] = "committed"
		record["actualDecisionId"] = ""
		record["updatedAtMsec"] = Time.get_ticks_msec()
		_records_by_id[observation_id] = record
	_observation_ids_by_decision.erase(normalized)


func mark_result(decision_id: String, ok: bool, failure_code := "") -> void:
	var normalized := decision_id.strip_edges()
	for observation_id: String in _decision_observation_ids(normalized):
		if not _records_by_id.has(observation_id):
			continue
		var record := _records_by_id[observation_id] as Dictionary
		if ok:
			record["status"] = "perceived"
			record["perceived"] = true
			record["failureCode"] = ""
		else:
			record["status"] = "failed"
			record["failed"] = true
			record["failureCode"] = failure_code.strip_edges()
		record["updatedAtMsec"] = Time.get_ticks_msec()
		_records_by_id[observation_id] = record
	_release_completed_decision(normalized)


func mark_failed(observation_id: String, failure_code: String) -> void:
	var normalized := observation_id.strip_edges()
	if not _records_by_id.has(normalized):
		return
	var record := _records_by_id[normalized] as Dictionary
	record["status"] = "failed"
	record["failed"] = true
	record["failureCode"] = failure_code.strip_edges()
	record["updatedAtMsec"] = Time.get_ticks_msec()
	_records_by_id[normalized] = record
	_remove_pending(String(record.get("targetResidentId", "")), normalized)


func mark_pending_failed(resident_id: String, failure_code: String) -> void:
	for observation_id: String in _pending_for_resident(resident_id):
		mark_failed(observation_id, failure_code)


func mark_outcome(observation_id: String, outcome: String) -> Dictionary:
	var normalized_id := observation_id.strip_edges()
	var normalized_outcome := outcome.strip_edges().to_lower()
	if not _records_by_id.has(normalized_id):
		return _failure("RUNTIME_OBSERVATION_NOT_FOUND")
	if normalized_outcome not in OUTCOMES:
		return _failure("RUNTIME_OBSERVATION_OUTCOME_INVALID")
	var record := _records_by_id[normalized_id] as Dictionary
	record["outcome"] = normalized_outcome
	record["ineffective"] = normalized_outcome in ["not_adopted", "ineffective"]
	if bool(record.get("ineffective", false)):
		record["status"] = "ineffective"
	record["updatedAtMsec"] = Time.get_ticks_msec()
	_records_by_id[normalized_id] = record
	return {"ok": true, "observation": record.duplicate(true)}


func audit_snapshot(observation_id := "") -> Dictionary:
	var normalized := observation_id.strip_edges()
	if not normalized.is_empty():
		return (
			(_records_by_id[normalized] as Dictionary).duplicate(true)
			if _records_by_id.has(normalized)
			else {}
		)
	var records: Array[Dictionary] = []
	for record_id: String in _record_order:
		if _records_by_id.has(record_id):
			records.append(
				(_records_by_id[record_id] as Dictionary).duplicate(true),
			)
	return {
		"records": records,
		"pendingResidentIds": pending_resident_ids(),
	}


func capture_state() -> Dictionary:
	var records: Array[Dictionary] = []
	for observation_id: String in _record_order:
		if _records_by_id.has(observation_id):
			records.append(
				(_records_by_id[observation_id] as Dictionary).duplicate(true),
			)
	return {
		"ok": true,
		"observationState": {
			"stateVersion": STATE_VERSION,
			"sequence": _sequence,
			"records": records,
		},
	}


func apply_state(value: Variant, valid_resident_ids: Array[String]) -> Dictionary:
	var validation := _validate_state(value, valid_resident_ids)
	if not bool(validation.get("ok", false)):
		return validation
	var state := validation.get("observationState", {}) as Dictionary
	reset()
	_sequence = int(state.get("sequence", 0))
	for record_value: Variant in state.get("records", []) as Array:
		var record := (record_value as Dictionary).duplicate(true)
		var observation_id := String(record.get("observationId", ""))
		var resident_id := String(record.get("targetResidentId", ""))
		# An in-flight decision is not part of the joint save contract. Recover an
		# undelivered observation at the stable committed boundary.
		if (
			not bool(record.get("stored", false))
			and not bool(record.get("failed", false))
			and not bool(record.get("perceived", false))
		):
			record["status"] = "committed"
			record["actualDecisionId"] = ""
			var pending := _pending_for_resident(resident_id)
			pending.append(observation_id)
			_pending_by_resident[resident_id] = pending
		_records_by_id[observation_id] = record
		_record_order.append(observation_id)
	return {
		"ok": true,
		"errorCode": "",
		"retryable": false,
		"observationCount": _record_order.size(),
	}


func _validate_state(
	value: Variant,
	valid_resident_ids: Array[String],
) -> Dictionary:
	if not value is Dictionary:
		return _failure("RUNTIME_OBSERVATION_STATE_INVALID")
	var state := value as Dictionary
	if (
		state.size() != 3
		or not state.has("stateVersion")
		or not state.has("sequence")
		or not state.has("records")
		or not state.get("stateVersion") is int
		or int(state.get("stateVersion", -1)) != STATE_VERSION
		or not state.get("sequence") is int
		or int(state.get("sequence", -1)) < 0
		or not state.get("records") is Array
		or (state.get("records", []) as Array).size() > MAX_AUDIT_RECORDS
	):
		return _failure("RUNTIME_OBSERVATION_STATE_INVALID")
	var ids: Dictionary = {}
	var normalized_records: Array[Dictionary] = []
	for record_value: Variant in state.get("records", []) as Array:
		var record_result := _validate_persistent_record(
			record_value,
			valid_resident_ids,
		)
		if not bool(record_result.get("ok", false)):
			return record_result
		var record := record_result.get("record", {}) as Dictionary
		var observation_id := String(record.get("observationId", ""))
		if ids.has(observation_id):
			return _failure("RUNTIME_OBSERVATION_STATE_INVALID")
		ids[observation_id] = true
		normalized_records.append(record)
	return {
		"ok": true,
		"observationState": {
			"stateVersion": STATE_VERSION,
			"sequence": int(state.get("sequence", 0)),
			"records": normalized_records,
		},
	}


func _validate_persistent_record(
	value: Variant,
	valid_resident_ids: Array[String],
) -> Dictionary:
	if not value is Dictionary:
		return _failure("RUNTIME_OBSERVATION_STATE_INVALID")
	var record := value as Dictionary
	var expected_fields: Array[String] = [
		"observationId", "targetResidentId", "kind", "rawText", "status",
		"outcome", "committed", "stored", "perceived", "failed",
		"ineffective", "actualDecisionId", "dispatchAttempts", "deliveryCount",
		"createdAtMsec", "updatedAtMsec", "createdWorldTime", "failureCode",
		"rootMemoryId", "rootClaimId",
	]
	if record.size() != expected_fields.size():
		return _failure("RUNTIME_OBSERVATION_STATE_INVALID")
	for field_name: String in expected_fields:
		if not record.has(field_name):
			return _failure("RUNTIME_OBSERVATION_STATE_INVALID")
	var observation_id := String(record.get("observationId", "")).strip_edges()
	var resident_id := String(record.get("targetResidentId", "")).strip_edges()
	var kind_result := _normalize_kind(String(record.get("kind", "")))
	var status := String(record.get("status", ""))
	var outcome := String(record.get("outcome", ""))
	var raw_text := String(record.get("rawText", ""))
	if (
		not _id_is_safe(observation_id)
		or resident_id.is_empty()
		or not valid_resident_ids.has(resident_id)
		or not bool(kind_result.get("ok", false))
		or raw_text.strip_edges().is_empty()
		or raw_text.length() > MAX_TEXT_CHARS
		or status not in RECORD_STATUSES
		or outcome not in OUTCOMES
		or not record.get("createdWorldTime") is Dictionary
	):
		return _failure("RUNTIME_OBSERVATION_STATE_INVALID")
	for bool_field: String in [
		"committed", "stored", "perceived", "failed", "ineffective",
	]:
		if not record.get(bool_field) is bool:
			return _failure("RUNTIME_OBSERVATION_STATE_INVALID")
	for int_field: String in [
		"dispatchAttempts", "deliveryCount", "createdAtMsec", "updatedAtMsec",
	]:
		if not record.get(int_field) is int or int(record.get(int_field, -1)) < 0:
			return _failure("RUNTIME_OBSERVATION_STATE_INVALID")
	for string_field: String in [
		"actualDecisionId", "failureCode", "rootMemoryId", "rootClaimId",
	]:
		if not record.get(string_field) is String:
			return _failure("RUNTIME_OBSERVATION_STATE_INVALID")
	var root_memory_id := String(record.get("rootMemoryId", ""))
	var root_claim_id := String(record.get("rootClaimId", ""))
	if root_memory_id.is_empty() != root_claim_id.is_empty():
		return _failure("RUNTIME_OBSERVATION_STATE_INVALID")
	if (
		not root_claim_id.is_empty()
		and root_claim_id != "runtime_observation:%s" % observation_id
	):
		return _failure("RUNTIME_OBSERVATION_STATE_INVALID")
	var normalized := record.duplicate(true)
	normalized["observationId"] = observation_id
	normalized["targetResidentId"] = resident_id
	normalized["kind"] = String(kind_result.get("kind", ""))
	return {"ok": true, "record": normalized}


func _normalize_kind(value: String) -> Dictionary:
	match value.strip_edges().to_lower():
		"":
			return {"ok": true, "kind": ""}
		"u0":
			return {"ok": true, "kind": "U0"}
		"u+", "u_plus", "uplus":
			return {"ok": true, "kind": "U+"}
		"u-", "u_minus", "uminus":
			return {"ok": true, "kind": "U-"}
	return {"ok": false, "kind": ""}


func _pending_for_resident(resident_id: String) -> Array[String]:
	var result: Array[String] = []
	if _pending_by_resident.get(resident_id) is Array:
		result.assign(_pending_by_resident[resident_id])
	return result


func _decision_observation_ids(decision_id: String) -> Array[String]:
	var result: Array[String] = []
	if _observation_ids_by_decision.get(decision_id) is Array:
		result.assign(_observation_ids_by_decision[decision_id])
	return result


func _release_completed_decision(decision_id: String) -> void:
	var ids := _decision_observation_ids(decision_id)
	if ids.is_empty():
		return
	for observation_id: String in ids:
		if not _records_by_id.has(observation_id):
			continue
		var record := _records_by_id[observation_id] as Dictionary
		if (
			not bool(record.get("stored", false))
			or not (
				bool(record.get("perceived", false))
				or bool(record.get("failed", false))
			)
		):
			return
	_observation_ids_by_decision.erase(decision_id)


func _remove_pending(resident_id: String, observation_id: String) -> void:
	var pending := _pending_for_resident(resident_id)
	pending.erase(observation_id)
	if pending.is_empty():
		_pending_by_resident.erase(resident_id)
	else:
		_pending_by_resident[resident_id] = pending


func _prune_audit() -> void:
	while _record_order.size() > MAX_AUDIT_RECORDS:
		var removable_index := -1
		for index in _record_order.size():
			var observation_id := _record_order[index]
			var record := _records_by_id.get(observation_id, {}) as Dictionary
			if (
				String(record.get("kind", "")) != "U0"
				and String(record.get("status", "")) not in ["committed", "injected"]
			):
				removable_index = index
				break
		if removable_index < 0:
			return
		var removed_id: String = _record_order.pop_at(removable_index)
		_records_by_id.erase(removed_id)


func _id_is_safe(value: String) -> bool:
	if value.is_empty() or value.length() > 128:
		return false
	for character in value:
		if not (
			character == "-"
			or character == "_"
			or character == ":"
			or character == "."
			or character.is_valid_identifier()
			or character.is_valid_int()
		):
			return false
	return true


func _failure(error_code: String) -> Dictionary:
	return {
		"ok": false,
		"errorCode": error_code,
		"retryable": false,
	}
