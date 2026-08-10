class_name TownExperimentScenarioState
extends RefCounted


const AgentJsonScript := preload("res://agent/AgentJson.gd")
const ObservationAdapterScript := preload(
	"res://world/integration/TownRuntimeObservationAdapter.gd"
)
const STATE_VERSION := 1
const MAX_U0_OBSERVATIONS := 32
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
		or int(state.get("stateVersion", -1)) != STATE_VERSION
		or not state.get("scenario") is Dictionary
		or not state.get("observationState") is Dictionary
	):
		return _failure("EXPERIMENT_STATE_INVALID")
	var scenario_validation := _validate_saved_scenario(
		state.get("scenario"),
		valid_resident_ids,
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
		},
	}


func _validate_saved_scenario(
	value: Variant,
	valid_resident_ids: Array[String],
) -> Dictionary:
	if not value is Dictionary:
		return _failure("EXPERIMENT_STATE_INVALID")
	var saved := value as Dictionary
	if saved.size() != 4:
		return _failure("EXPERIMENT_STATE_INVALID")
	var status := String(saved.get("status", ""))
	if status == "none":
		return (
			{"ok": true, "scenario": _empty_scenario()}
			if saved == _empty_scenario()
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
	return {"ok": true, "scenario": normalized}


func _validate_scenario_transport_link(
	scenario: Dictionary,
	observation_state: Dictionary,
) -> Dictionary:
	var expected_u0: Dictionary = {}
	for observation_value: Variant in scenario.get("u0Observations", []) as Array:
		var observation := observation_value as Dictionary
		expected_u0[String(observation.get("observationId", ""))] = observation
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
	}


func _failure(error_code: String) -> Dictionary:
	return {
		"ok": false,
		"errorCode": error_code,
		"retryable": false,
	}
