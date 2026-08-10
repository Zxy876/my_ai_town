class_name AgentContractRuntimeObservations
extends RefCounted


const MAX_TEXT_CHARS := 2000


static func validate(observations: Array, errors: Array[String]) -> void:
	var observation_ids := {}
	for index in observations.size():
		var path := "runtime_observations[%d]" % index
		var value: Variant = observations[index]
		if typeof(value) != TYPE_DICTIONARY:
			errors.append("%s 必须是对象" % path)
			continue
		var observation := value as Dictionary
		AgentContractIdentity._validate_allowed_fields(
			observation,
			["observation_id", "text"],
			path,
			errors,
		)
		var observation_id := AgentContract._require_non_empty_string(
			observation,
			"observation_id",
			"%s.observation_id" % path,
			errors,
		)
		if not observation_id.is_empty() and observation_ids.has(observation_id):
			errors.append("%s.observation_id 在本次观察中重复" % path)
		observation_ids[observation_id] = true
		var text := AgentContract._require_non_empty_string(
			observation,
			"text",
			"%s.text" % path,
			errors,
		)
		if text.length() > MAX_TEXT_CHARS:
			errors.append("%s.text 超过 %d 字" % [path, MAX_TEXT_CHARS])
