class_name TownExperimentScenarioState
extends RefCounted


const AgentJsonScript := preload("res://agent/AgentJson.gd")
const ObservationAdapterScript := preload(
	"res://world/integration/TownRuntimeObservationAdapter.gd"
)
const LEGACY_STATE_VERSION := 1
const STATE_VERSION := 2
const MAX_U0_OBSERVATIONS := 32
const MAX_GLOBAL_INTENT_VERSIONS := 256
const MAX_ID_CHARS := 128

var _observations: RefCounted = ObservationAdapterScript.new()
var _scenario: Dictionary = _empty_scenario()


func reset() -> void:
	_observations.reset()
	_scenario = _empty_scenario()


func configure_new_session(
	value: Variant,
	valid_resident_ids: Array[String],
) -> Dictionary:
	var validation := _validate_scenario(value, valid_resident_ids)
	if not bool(validation.get("ok", false)):
		return validation
	reset()
	_scenario = (
		validation.get("scenario", _empty_scenario()) as Dictionary
	).duplicate(true)
	return {
		"ok": true,
		"errorCode": "",
		"retryable": false,
		"scenario": _scenario.duplicate(true),
	}


func activate_initial_conditions(
	valid_resident_ids: Array[String],
	world_time: Dictionary,
) -> Dictionary:
	if String(_scenario.get("status", "none")) == "none":
		return {
			"ok": true,
			"changed": false,
			"pendingResidentIds": [],
		}
	if String(_scenario.get("status", "")) == "activated":
		return {
			"ok": true,
			"changed": false,
			"pendingResidentIds": _observations.pending_resident_ids(),
		}
	var staged := _scenario.get("u0Observations", []) as Array
	for observation_value: Variant in staged:
		var observation := observation_value as Dictionary
		var queued := _observations.enqueue({
			"observationId": observation.get("observationId", ""),
			"targetResidentId": observation.get("targetResidentId", ""),
			"kind": "U0",
			"text": observation.get("rawText", ""),
			"createdWorldTime": world_time.duplicate(true),
		}, valid_resident_ids) as Dictionary
		if not bool(queued.get("ok", false)):
			return queued
	_scenario["status"] = "activated"
	return {
		"ok": true,
		"changed": true,
		"pendingResidentIds": _observations.pending_resident_ids(),
	}


# The runtime player entry is intentionally not an initial-condition entry.
func enqueue(request: Dictionary, valid_resident_ids: Array[String]) -> Dictionary:
	if String(request.get("kind", request.get("uKind", ""))).strip_edges().to_lower() == "u0":
		return _failure("U0_INITIALIZATION_ONLY")
	return _observations.enqueue(request, valid_resident_ids) as Dictionary


func append_global_intent_after_restore(
	request: Dictionary,
	valid_resident_ids: Array[String],
	world_time: Dictionary,
) -> Dictionary:
	var raw_text := String(request.get("text", request.get("rawText", "")))
	var session_id := String(request.get("sessionId", "")).strip_edges()
	var source_save_revision := int(request.get("sourceSaveRevision", 0))
	if (
		raw_text.strip_edges().is_empty()
		or raw_text.length() > ObservationAdapterScript.MAX_TEXT_CHARS
		or session_id.is_empty()
		or source_save_revision <= 0
		or valid_resident_ids.is_empty()
	):
		return _failure("GLOBAL_INTENT_CONTINUATION_INVALID")
	var resident_ids := valid_resident_ids.duplicate()
	resident_ids.sort()
	for resident_id: String in resident_ids:
		if resident_id.strip_edges().is_empty():
			return _failure("GLOBAL_INTENT_CONTINUATION_INVALID")
	var status := String(_scenario.get("status", "none"))
	if status == "staged":
		return _failure("GLOBAL_INTENT_CONTINUATION_BASELINE_PENDING")
	if status == "none":
		return _failure("GLOBAL_INTENT_CONTINUATION_BASELINE_MISSING")
	if (
		status != "activated"
		or (_scenario.get("u0Observations", []) as Array).is_empty()
	):
		return _failure("GLOBAL_INTENT_CONTINUATION_INVALID")
	var continuations := (
		_scenario.get("u0Continuations", []) as Array
	).duplicate(true)
	if continuations.size() >= MAX_GLOBAL_INTENT_VERSIONS:
		return _failure("GLOBAL_INTENT_CONTINUATION_LIMIT_REACHED")
	var current := _current_global_intent_version()
	if not current.is_empty() and String(current.get("rawText", "")) == raw_text:
		return {
			"ok": true,
			"errorCode": "",
			"retryable": false,
			"changed": false,
			"duplicate": true,
			"version": current.duplicate(true),
			"pendingResidentIds": _observations.pending_resident_ids(),
		}
	var has_initial_version := not (
		_scenario.get("u0Observations", []) as Array
	).is_empty()
	var version_number := continuations.size() + (1 if has_initial_version else 0)
	var parent_version_id := (
		String((continuations[-1] as Dictionary).get("versionId", ""))
		if not continuations.is_empty()
		else _initial_version_id(_scenario)
		if has_initial_version
		else ""
	)
	var version_id := "u0-v%d-%s" % [
		version_number,
		String(AgentJsonScript.content_sha256({
			"sessionId": session_id,
			"parentVersionId": parent_version_id,
			"sourceSaveRevision": source_save_revision,
			"text": raw_text,
		})).left(20),
	]
	var captured := _observations.capture_state() as Dictionary
	if not bool(captured.get("ok", false)):
		return captured
	var staged_observations: RefCounted = ObservationAdapterScript.new()
	var staged_restore := staged_observations.apply_state(
		captured.get("observationState"),
		resident_ids,
	) as Dictionary
	if not bool(staged_restore.get("ok", false)):
		return staged_restore
	var deliveries: Array[Dictionary] = []
	for resident_id: String in resident_ids:
		var observation_id := "scenario-u0-%s-%s" % [
			version_id,
			String(AgentJsonScript.content_sha256({
				"versionId": version_id,
				"targetResidentId": resident_id,
			})).left(16),
		]
		var queued := staged_observations.enqueue({
			"observationId": observation_id,
			"targetResidentId": resident_id,
			"kind": "U0",
			"text": raw_text,
			"createdWorldTime": world_time.duplicate(true),
		}, resident_ids) as Dictionary
		if not bool(queued.get("ok", false)):
			return queued
		deliveries.append({
			"observationId": observation_id,
			"targetResidentId": resident_id,
		})
	var version := {
		"versionNumber": version_number,
		"versionId": version_id,
		"parentVersionId": parent_version_id,
		"sourceSaveRevision": source_save_revision,
		"rawText": raw_text,
		"createdWorldTime": world_time.duplicate(true),
		"deliveries": deliveries,
	}
	continuations.append(version)
	_observations = staged_observations
	_scenario["u0Continuations"] = continuations
	return {
		"ok": true,
		"errorCode": "",
		"retryable": false,
		"changed": true,
		"duplicate": false,
		"version": version.duplicate(true),
		"pendingResidentIds": _observations.pending_resident_ids(),
	}


func global_intent_summary() -> Dictionary:
	var current := _current_global_intent_version()
	return {
		"configured": not current.is_empty(),
		"versionNumber": int(current.get("versionNumber", -1)),
		"versionId": String(current.get("versionId", "")),
		"rawText": String(current.get("rawText", "")),
		"continuationCount": (
			_scenario.get("u0Continuations", []) as Array
		).size(),
	}


func pending_resident_ids() -> Array[String]:
	return _observations.pending_resident_ids()


func attach_to_wake(
	resident_id: String,
	decision_id: String,
	wake_packet: Dictionary,
) -> Dictionary:
	return _observations.attach_to_wake(
		resident_id,
		decision_id,
		wake_packet,
	) as Dictionary


func mark_stored(decision_id: String) -> Array[Dictionary]:
	return _observations.mark_stored(decision_id) as Array[Dictionary]


func mark_root_memory(observation_id: String, mapping: Dictionary) -> Dictionary:
	return _observations.mark_root_memory(observation_id, mapping) as Dictionary


func release_dispatch(decision_id: String) -> void:
	_observations.release_dispatch(decision_id)


func mark_result(decision_id: String, ok: bool, failure_code := "") -> void:
	_observations.mark_result(decision_id, ok, failure_code)


func mark_failed(observation_id: String, failure_code: String) -> void:
	_observations.mark_failed(observation_id, failure_code)


func mark_pending_failed(resident_id: String, failure_code: String) -> void:
	_observations.mark_pending_failed(resident_id, failure_code)


func mark_outcome(observation_id: String, outcome: String) -> Dictionary:
	return _observations.mark_outcome(observation_id, outcome) as Dictionary


func audit_snapshot(observation_id := "") -> Dictionary:
	var audit := _observations.audit_snapshot(observation_id) as Dictionary
	if observation_id.strip_edges().is_empty():
		audit["scenario"] = _scenario.duplicate(true)
	return audit


func capture_state() -> Dictionary:
	var transport_capture := _observations.capture_state() as Dictionary
	if not bool(transport_capture.get("ok", false)):
		return transport_capture
	return {
		"ok": true,
		"experimentState": {
			"stateVersion": STATE_VERSION,
			"scenario": _scenario.duplicate(true),
			"observationState": (
				transport_capture.get("observationState", {}) as Dictionary
			).duplicate(true),
		},
	}


func apply_state(
	value: Variant,
	valid_resident_ids: Array[String],
) -> Dictionary:
	var validation := validate_persistent_state(value, valid_resident_ids)
	if not bool(validation.get("ok", false)):
		return validation
	var state := validation.get("experimentState", {}) as Dictionary
	var applied := _observations.apply_state(
		state.get("observationState"),
		valid_resident_ids,
	) as Dictionary
	if not bool(applied.get("ok", false)):
		return applied
	_scenario = (state.get("scenario", {}) as Dictionary).duplicate(true)
	return {
		"ok": true,
		"errorCode": "",
		"retryable": false,
		"scenario": _scenario.duplicate(true),
	}


func validate_persistent_state(
	value: Variant,
	valid_resident_ids: Array[String],
) -> Dictionary:
	if not value is Dictionary:
		return _failure("EXPERIMENT_STATE_INVALID")
	var state := value as Dictionary
	if (
		state.size() != 3
		or not state.get("stateVersion") is int
		or int(state.get("stateVersion", -1)) not in [
			LEGACY_STATE_VERSION, STATE_VERSION,
		]
		or not state.get("scenario") is Dictionary
		or not state.get("observationState") is Dictionary
	):
		return _failure("EXPERIMENT_STATE_INVALID")
	var scenario_validation := _validate_saved_scenario(
		state.get("scenario"),
		valid_resident_ids,
		int(state.get("stateVersion", -1)),
	)
	if not bool(scenario_validation.get("ok", false)):
		return scenario_validation
	var scratch := ObservationAdapterScript.new()
	var observation_validation := scratch.apply_state(
		state.get("observationState"),
		valid_resident_ids,
	) as Dictionary
	if not bool(observation_validation.get("ok", false)):
		return observation_validation
	var observation_capture := scratch.capture_state() as Dictionary
	var normalized_scenario := (
		scenario_validation.get("scenario", {}) as Dictionary
	).duplicate(true)
	var normalized_observation_state := (
		observation_capture.get("observationState", {}) as Dictionary
	).duplicate(true)
	var cross_validation := _validate_scenario_transport_link(
		normalized_scenario,
		normalized_observation_state,
	)
	if not bool(cross_validation.get("ok", false)):
		return cross_validation
	return {
		"ok": true,
		"experimentState": {
			"stateVersion": STATE_VERSION,
			"scenario": normalized_scenario,
			"observationState": normalized_observation_state,
		},
	}


func validate_scenario_definition(value: Variant) -> Dictionary:
	return _validate_scenario(value, [])


func _validate_scenario(
	value: Variant,
	valid_resident_ids: Array[String],
) -> Dictionary:
	if value == null or (value is Dictionary and (value as Dictionary).is_empty()):
		return {"ok": true, "scenario": _empty_scenario()}
	if not value is Dictionary:
		return _failure("EXPERIMENT_SCENARIO_INVALID")
	var source := value as Dictionary
	for key_value: Variant in source:
		if (
			not key_value is String
			or String(key_value) not in [
				"scenarioId", "episodeId", "u0Observations",
			]
		):
			return _failure("EXPERIMENT_SCENARIO_INVALID")
	var scenario_id := String(source.get("scenarioId", "")).strip_edges()
	var episode_id := String(source.get("episodeId", "common")).strip_edges()
	var observations_value: Variant = source.get("u0Observations", [])
	if (
		scenario_id.is_empty()
		or scenario_id.length() > MAX_ID_CHARS
		or episode_id.is_empty()
		or episode_id.length() > MAX_ID_CHARS
		or not observations_value is Array
		or (observations_value as Array).is_empty()
		or (observations_value as Array).size() > MAX_U0_OBSERVATIONS
	):
		return _failure("EXPERIMENT_SCENARIO_INVALID")
	var normalized: Array[Dictionary] = []
	for index in (observations_value as Array).size():
		var observation_value: Variant = (observations_value as Array)[index]
		if not observation_value is Dictionary:
			return _failure("EXPERIMENT_SCENARIO_INVALID")
		var observation := observation_value as Dictionary
		for key_value: Variant in observation:
			if (
				not key_value is String
				or String(key_value) not in ["targetResidentId", "text"]
			):
				return _failure("EXPERIMENT_SCENARIO_INVALID")
		var resident_id := String(observation.get("targetResidentId", "")).strip_edges()
		var raw_text := String(observation.get("text", ""))
		if (
			resident_id.is_empty()
			or (
				not valid_resident_ids.is_empty()
				and not valid_resident_ids.has(resident_id)
			)
			or raw_text.strip_edges().is_empty()
			or raw_text.length() > ObservationAdapterScript.MAX_TEXT_CHARS
		):
			return _failure("EXPERIMENT_SCENARIO_INVALID")
		var observation_id := "scenario-u0-%s" % String(
			AgentJsonScript.content_sha256({
				"scenarioId": scenario_id,
				"episodeId": episode_id,
				"targetResidentId": resident_id,
				"text": raw_text,
				"index": index,
			})
		).left(24)
		normalized.append({
			"observationId": observation_id,
			"targetResidentId": resident_id,
			"rawText": raw_text,
		})
	return {
		"ok": true,
		"scenario": {
			"scenarioId": scenario_id,
			"episodeId": episode_id,
			"status": "staged",
			"u0Observations": normalized,
			"u0Continuations": [],
		},
	}


func _validate_saved_scenario(
	value: Variant,
	valid_resident_ids: Array[String],
	persistent_state_version: int,
) -> Dictionary:
	if not value is Dictionary:
		return _failure("EXPERIMENT_STATE_INVALID")
	var saved := value as Dictionary
	var legacy := persistent_state_version == LEGACY_STATE_VERSION
	if saved.size() != (4 if legacy else 5):
		return _failure("EXPERIMENT_STATE_INVALID")
	var status := String(saved.get("status", ""))
	if status == "none":
		return (
			{"ok": true, "scenario": _empty_scenario()}
			if saved == (_legacy_empty_scenario() if legacy else _empty_scenario())
			else _failure("EXPERIMENT_STATE_INVALID")
		)
	if status not in ["staged", "activated"]:
		return _failure("EXPERIMENT_STATE_INVALID")
	if not saved.get("u0Observations") is Array:
		return _failure("EXPERIMENT_STATE_INVALID")
	var definition_observations: Array[Dictionary] = []
	for value_item: Variant in saved.get("u0Observations", []) as Array:
		if not value_item is Dictionary:
			return _failure("EXPERIMENT_STATE_INVALID")
		var item := value_item as Dictionary
		if (
			item.size() != 3
			or not item.get("observationId") is String
			or not item.get("targetResidentId") is String
			or not item.get("rawText") is String
		):
			return _failure("EXPERIMENT_STATE_INVALID")
		definition_observations.append({
			"targetResidentId": item.get("targetResidentId", ""),
			"text": item.get("rawText", ""),
		})
	var definition_validation := _validate_scenario({
		"scenarioId": saved.get("scenarioId", ""),
		"episodeId": saved.get("episodeId", ""),
		"u0Observations": definition_observations,
	}, valid_resident_ids)
	if not bool(definition_validation.get("ok", false)):
		return _failure("EXPERIMENT_STATE_INVALID")
	var normalized := definition_validation.get("scenario", {}) as Dictionary
	if normalized.get("u0Observations") != saved.get("u0Observations"):
		return _failure("EXPERIMENT_STATE_INVALID")
	normalized["status"] = status
	var continuation_validation := _validate_saved_continuations(
		saved.get("u0Continuations", []) if not legacy else [],
		normalized,
		valid_resident_ids,
	)
	if not bool(continuation_validation.get("ok", false)):
		return continuation_validation
	normalized["u0Continuations"] = (
		continuation_validation.get("continuations", []) as Array
	).duplicate(true)
	return {"ok": true, "scenario": normalized}


func _validate_saved_continuations(
	value: Variant,
	scenario: Dictionary,
	valid_resident_ids: Array[String],
) -> Dictionary:
	if not value is Array or (value as Array).size() > MAX_GLOBAL_INTENT_VERSIONS:
		return _failure("EXPERIMENT_STATE_INVALID")
	if (
		not (value as Array).is_empty()
		and String(scenario.get("status", "")) != "activated"
	):
		return _failure("EXPERIMENT_STATE_INVALID")
	var normalized: Array[Dictionary] = []
	var version_ids: Dictionary = {}
	var observation_ids: Dictionary = {}
	var has_initial_version := not (
		scenario.get("u0Observations", []) as Array
	).is_empty()
	var expected_version := 1 if has_initial_version else 0
	var expected_parent := _initial_version_id(scenario) if has_initial_version else ""
	for value_item: Variant in value as Array:
		if not value_item is Dictionary:
			return _failure("EXPERIMENT_STATE_INVALID")
		var version := value_item as Dictionary
		if not _has_exact_fields(version, [
			"versionNumber", "versionId", "parentVersionId",
			"sourceSaveRevision", "rawText", "createdWorldTime", "deliveries",
		]):
			return _failure("EXPERIMENT_STATE_INVALID")
		var version_number := int(version.get("versionNumber", -1))
		var version_id := String(version.get("versionId", "")).strip_edges()
		var parent_version_id := String(version.get("parentVersionId", "")).strip_edges()
		var raw_text := String(version.get("rawText", ""))
		if (
			not version.get("versionNumber") is int
			or version_number != expected_version
			or not _id_is_safe(version_id)
			or version_ids.has(version_id)
			or parent_version_id != expected_parent
			or not version.get("sourceSaveRevision") is int
			or int(version.get("sourceSaveRevision", 0)) <= 0
			or raw_text.strip_edges().is_empty()
			or raw_text.length() > ObservationAdapterScript.MAX_TEXT_CHARS
			or not version.get("createdWorldTime") is Dictionary
			or not version.get("deliveries") is Array
		):
			return _failure("EXPERIMENT_STATE_INVALID")
		var normalized_deliveries: Array[Dictionary] = []
		var delivered_resident_ids: Array[String] = []
		for delivery_value: Variant in version.get("deliveries", []) as Array:
			if not delivery_value is Dictionary:
				return _failure("EXPERIMENT_STATE_INVALID")
			var delivery := delivery_value as Dictionary
			if not _has_exact_fields(
				delivery,
				["observationId", "targetResidentId"],
			):
				return _failure("EXPERIMENT_STATE_INVALID")
			var observation_id := String(delivery.get("observationId", "")).strip_edges()
			var resident_id := String(delivery.get("targetResidentId", "")).strip_edges()
			if (
				not observation_id.begins_with("scenario-u0-")
				or not _id_is_safe(observation_id)
				or observation_ids.has(observation_id)
				or resident_id.is_empty()
				or delivered_resident_ids.has(resident_id)
				or (
					not valid_resident_ids.is_empty()
					and not valid_resident_ids.has(resident_id)
				)
			):
				return _failure("EXPERIMENT_STATE_INVALID")
			observation_ids[observation_id] = true
			delivered_resident_ids.append(resident_id)
			normalized_deliveries.append({
				"observationId": observation_id,
				"targetResidentId": resident_id,
			})
		if not valid_resident_ids.is_empty():
			var expected_residents := valid_resident_ids.duplicate()
			expected_residents.sort()
			delivered_resident_ids.sort()
			if delivered_resident_ids != expected_residents:
				return _failure("EXPERIMENT_STATE_INVALID")
		version_ids[version_id] = true
		normalized.append({
			"versionNumber": version_number,
			"versionId": version_id,
			"parentVersionId": parent_version_id,
			"sourceSaveRevision": int(version.get("sourceSaveRevision", 0)),
			"rawText": raw_text,
			"createdWorldTime": (
				version.get("createdWorldTime", {}) as Dictionary
			).duplicate(true),
			"deliveries": normalized_deliveries,
		})
		expected_version += 1
		expected_parent = version_id
	return {"ok": true, "continuations": normalized}


func _validate_scenario_transport_link(
	scenario: Dictionary,
	observation_state: Dictionary,
) -> Dictionary:
	var expected_u0: Dictionary = {}
	for observation_value: Variant in scenario.get("u0Observations", []) as Array:
		var observation := observation_value as Dictionary
		expected_u0[String(observation.get("observationId", ""))] = observation
	for version_value: Variant in scenario.get("u0Continuations", []) as Array:
		var version := version_value as Dictionary
		for delivery_value: Variant in version.get("deliveries", []) as Array:
			var delivery := delivery_value as Dictionary
			expected_u0[String(delivery.get("observationId", ""))] = {
				"observationId": delivery.get("observationId", ""),
				"targetResidentId": delivery.get("targetResidentId", ""),
				"rawText": version.get("rawText", ""),
			}
	var actual_u0: Dictionary = {}
	for record_value: Variant in observation_state.get("records", []) as Array:
		var record := record_value as Dictionary
		if String(record.get("kind", "")) != "U0":
			continue
		var observation_id := String(record.get("observationId", ""))
		if not expected_u0.has(observation_id):
			return _failure("EXPERIMENT_STATE_INVALID")
		var expected := expected_u0[observation_id] as Dictionary
		if (
			String(record.get("targetResidentId", ""))
			!= String(expected.get("targetResidentId", ""))
			or String(record.get("rawText", ""))
			!= String(expected.get("rawText", ""))
		):
			return _failure("EXPERIMENT_STATE_INVALID")
		actual_u0[observation_id] = true
	if (
		String(scenario.get("status", "none")) == "activated"
		and actual_u0.size() != expected_u0.size()
	):
		return _failure("EXPERIMENT_STATE_INVALID")
	if (
		String(scenario.get("status", "none")) in ["none", "staged"]
		and not actual_u0.is_empty()
	):
		return _failure("EXPERIMENT_STATE_INVALID")
	return {"ok": true}


func _empty_scenario() -> Dictionary:
	return {
		"scenarioId": "",
		"episodeId": "",
		"status": "none",
		"u0Observations": [],
		"u0Continuations": [],
	}


func _legacy_empty_scenario() -> Dictionary:
	return {
		"scenarioId": "",
		"episodeId": "",
		"status": "none",
		"u0Observations": [],
	}


func _current_global_intent_version() -> Dictionary:
	var continuations := _scenario.get("u0Continuations", []) as Array
	if not continuations.is_empty() and continuations[-1] is Dictionary:
		return (continuations[-1] as Dictionary).duplicate(true)
	var initial := _scenario.get("u0Observations", []) as Array
	if initial.is_empty() or not initial[0] is Dictionary:
		return {}
	return {
		"versionNumber": 0,
		"versionId": _initial_version_id(_scenario),
		"parentVersionId": "",
		"sourceSaveRevision": 0,
		"rawText": String((initial[0] as Dictionary).get("rawText", "")),
		"createdWorldTime": {},
		"deliveries": initial.duplicate(true),
	}


func _initial_version_id(scenario: Dictionary) -> String:
	if (scenario.get("u0Observations", []) as Array).is_empty():
		return ""
	return "u0-v0-%s" % String(AgentJsonScript.content_sha256({
		"scenarioId": scenario.get("scenarioId", ""),
		"episodeId": scenario.get("episodeId", ""),
		"observations": scenario.get("u0Observations", []),
	})).left(20)


func _has_exact_fields(value: Dictionary, fields: Array[String]) -> bool:
	if value.size() != fields.size():
		return false
	for field_name: String in fields:
		if not value.has(field_name):
			return false
	return true


func _id_is_safe(value: String) -> bool:
	if value.is_empty() or value.length() > MAX_ID_CHARS:
		return false
	for character in value:
		if not (
			character == "-"
			or character == "_"
			or character == ":"
			or (character >= "0" and character <= "9")
			or (character >= "A" and character <= "Z")
			or (character >= "a" and character <= "z")
		):
			return false
	return true


func _failure(error_code: String) -> Dictionary:
	return {
		"ok": false,
		"errorCode": error_code,
		"retryable": false,
	}
