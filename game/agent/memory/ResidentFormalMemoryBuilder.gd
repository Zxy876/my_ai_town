class_name AgentResidentFormalMemoryBuilder
extends RefCounted


const AgentJsonScript := preload("res://agent/AgentJson.gd")
const MatcherScript := preload("res://agent/memory/ResidentMemoryEvidenceMatcher.gd")
const ReappraiserScript := preload("res://agent/memory/ResidentMemoryReappraiser.gd")
const MAX_FORMAL_ENTRIES := 256
const PROTECTED_MEMORY_STATES: Array[String] = [
	"influencing", "doubtful", "anomalous", "corrected",
]
const COGNITIVE_EVENT_TYPES: Array[String] = [
	"搭话", "旁听", "对方答话", "对话结束", "公告发布", "公告阅读",
	"公告转告", "钟声公告", "正式通知送达", "营业状态变化",
	"身体状况变化", "承诺条件变化", "天气变了", "冲突见闻",
	"有人来了", "有人走了",
	"居民死亡",
]

var _resident_id: String
var _matcher: AgentResidentMemoryEvidenceMatcher = MatcherScript.new()
var _reappraiser: AgentResidentMemoryReappraiser = ReappraiserScript.new()


func _init(resident_id: String) -> void:
	_resident_id = resident_id


func build(
	old_archive: Dictionary,
	old_log: Dictionary,
	evidence_items: Array,
	working_summary: Dictionary,
) -> Dictionary:
	var revision := maxi(int(old_archive.get("revision", 0)), int(old_log.get("revision", 0))) + 1
	var entries := (old_archive.get("entries", []) as Array).duplicate(true)
	var interventions := (old_log.get("interventions", []) as Array).duplicate(true)
	var changed := false
	for evidence_item_value: Variant in evidence_items:
		if typeof(evidence_item_value) != TYPE_DICTIONARY:
			continue
		var evidence_item := evidence_item_value as Dictionary
		var wake := evidence_item.get("wake_packet", {}) as Dictionary
		for observation_value: Variant in wake.get(
			"runtime_observations",
			[],
		) as Array:
			if typeof(observation_value) != TYPE_DICTIONARY:
				continue
			var observation_evidence := _runtime_observation_evidence(
				observation_value as Dictionary,
				wake,
			)
			if not observation_evidence.is_empty():
				changed = (
					_merge_evidence(
						entries,
						interventions,
						observation_evidence,
						revision,
					)
					or changed
				)
		for event_value: Variant in wake.get("events", []) as Array:
			if typeof(event_value) != TYPE_DICTIONARY:
				continue
			var event := event_value as Dictionary
			if String(event.get("type", "")) not in COGNITIVE_EVENT_TYPES:
				continue
			for evidence in _event_evidence(event, working_summary):
				changed = (
					_merge_evidence(
						entries,
						interventions,
						evidence,
						revision,
					)
					or changed
				)
		var intents := evidence_item.get("matched_intents", []) as Array
		var intent_by_id := {}
		for intent_value: Variant in intents:
			if typeof(intent_value) == TYPE_DICTIONARY:
				var intent := intent_value as Dictionary
				intent_by_id[String(intent.get("action_id", ""))] = intent
		for result_value: Variant in wake.get("action_results", []) as Array:
			if typeof(result_value) != TYPE_DICTIONARY:
				continue
			var action_result := result_value as Dictionary
			var action_id := String(action_result.get("action_id", ""))
			var intent := intent_by_id.get(action_id, {}) as Dictionary
			changed = (
				_merge_evidence(
					entries,
					interventions,
					_action_evidence(action_result, intent, wake, working_summary),
					revision,
				)
				or changed
			)
	if not changed:
		return {
			"ok": true,
			"changed": false,
			"convergence": {"removed_memory_ids": []},
			"archive": old_archive.duplicate(true),
			"intervention_log": old_log.duplicate(true),
		}
	var convergence := _converge_entries(entries, interventions)
	if not bool(convergence.get("ok", false)):
		return convergence
	entries = (convergence.get("entries", []) as Array).duplicate(true)
	return {
		"ok": true,
		"changed": true,
		"convergence": {
			"removed_memory_ids": (
				convergence.get("removed_memory_ids", []) as Array
			).duplicate(),
		},
		"archive": {
			"state_version": int(old_archive.get("state_version", 1)),
			"resident_id": _resident_id,
			"revision": revision,
			"entries": entries,
		},
		"intervention_log": {
			"state_version": int(old_log.get("state_version", 1)),
			"resident_id": _resident_id,
			"revision": revision,
			"interventions": interventions,
		},
	}


func add_reflection(
	old_archive: Dictionary,
	old_log: Dictionary,
	reflection: Dictionary,
	world_time: Variant,
) -> Dictionary:
	var text := String(reflection.get("text", "")).strip_edges()
	var evidence_refs: Array = (
		reflection.get("evidence_refs", []) as Array
	).duplicate()
	if text.is_empty() or evidence_refs.is_empty():
		return {
			"ok": true,
			"changed": false,
			"convergence": {"removed_memory_ids": []},
			"archive": old_archive.duplicate(true),
			"intervention_log": old_log.duplicate(true),
		}
	var stable_refs: Array[String] = []
	for source_ref_value: Variant in evidence_refs:
		var source_ref := String(source_ref_value).strip_edges()
		if not source_ref.is_empty() and not stable_refs.has(source_ref):
			stable_refs.append(source_ref)
	stable_refs.sort()
	var claim_root := "reflection:%s" % String(
		AgentJsonScript.content_sha256({
			"resident_id": _resident_id,
			"evidence_refs": stable_refs,
		})
	).left(20)
	var revision := maxi(
		int(old_archive.get("revision", 0)),
		int(old_log.get("revision", 0)),
	) + 1
	var entries := (old_archive.get("entries", []) as Array).duplicate(true)
	var interventions := (old_log.get("interventions", []) as Array).duplicate(true)
	var reflection_evidence := _evidence_record(
		text,
		text,
		[],
		[],
		_topics(text),
		world_time,
		"firsthand",
		"",
		claim_root,
		stable_refs,
	)
	reflection_evidence["initial_confidence"] = 70
	var changed := _merge_evidence(
		entries,
		interventions,
		reflection_evidence,
		revision,
	)
	if not changed:
		return {
			"ok": true,
			"changed": false,
			"convergence": {"removed_memory_ids": []},
			"archive": old_archive.duplicate(true),
			"intervention_log": old_log.duplicate(true),
		}
	var convergence := _converge_entries(entries, interventions)
	if not bool(convergence.get("ok", false)):
		return convergence
	return {
		"ok": true,
		"changed": true,
		"convergence": {
			"removed_memory_ids": (
				convergence.get("removed_memory_ids", []) as Array
			).duplicate(),
		},
		"archive": {
			"state_version": int(old_archive.get("state_version", 1)),
			"resident_id": _resident_id,
			"revision": revision,
			"entries": (
				convergence.get("entries", []) as Array
			).duplicate(true),
		},
		"intervention_log": {
			"state_version": int(old_log.get("state_version", 1)),
			"resident_id": _resident_id,
			"revision": revision,
			"interventions": interventions,
		},
	}


func _converge_entries(entries_value: Array, interventions: Array) -> Dictionary:
	var entries := entries_value.duplicate(true)
	var removed_memory_ids: Array[String] = []
	while entries.size() > MAX_FORMAL_ENTRIES:
		var candidate_index := _oldest_settled_memory_index(
			entries,
			interventions,
		)
		if candidate_index < 0:
			return {
				"ok": false,
				"capacity_blocked": true,
				"errors": [
					(
						"居民正式记忆已达到 %d 条上限；当前条目都仍在影响、存疑、异常、已修正或带有玩家介入/认知审计，不能静默删除"
					) % MAX_FORMAL_ENTRIES,
				],
			}
		var removed := entries[candidate_index] as Dictionary
		removed_memory_ids.append(String(removed.get("memory_id", "")))
		entries.remove_at(candidate_index)
	return {
		"ok": true,
		"entries": entries,
		"removed_memory_ids": removed_memory_ids,
	}


func _oldest_settled_memory_index(entries: Array, interventions: Array) -> int:
	var intervention_memory_ids := _protected_intervention_memory_ids(interventions)
	var best_index := -1
	var best_revision := 0
	for index in range(entries.size()):
		if typeof(entries[index]) != TYPE_DICTIONARY:
			continue
		var entry := entries[index] as Dictionary
		var memory_id := String(entry.get("memory_id", ""))
		var state := String(entry.get("state", "past"))
		if (
			state in PROTECTED_MEMORY_STATES
			or state != "past"
			or intervention_memory_ids.has(memory_id)
			or _is_scenario_u0_entry(entry)
		):
			continue
		var revision := int(entry.get(
			"updated_revision",
			entry.get("created_revision", 0),
		))
		if best_index < 0 or revision < best_revision:
			best_index = index
			best_revision = revision
	return best_index


func _is_scenario_u0_entry(entry: Dictionary) -> bool:
	for evidence_ref_value: Variant in entry.get("evidence_refs", []) as Array:
		if String(evidence_ref_value).begins_with(
			"runtime_observation:scenario-u0-"
		):
			return true
	return false


func _protected_intervention_memory_ids(interventions: Array) -> Dictionary:
	var protected_ids := {}
	for intervention_value: Variant in interventions:
		if typeof(intervention_value) != TYPE_DICTIONARY:
			continue
		var intervention := intervention_value as Dictionary
		if _is_automatic_settlement_record(intervention):
			continue
		var memory_id := String(intervention.get("memory_id", ""))
		if not memory_id.is_empty():
			protected_ids[memory_id] = true
	return protected_ids


func _is_automatic_settlement_record(intervention: Dictionary) -> bool:
	return (
		String(intervention.get("intervention_id", "")).begins_with("aging-")
		and String(intervention.get("kind", "")) == "soften"
		and String(intervention.get("status", "")) == "superseded"
		and String(intervention.get("player_text", "")).is_empty()
	)


func _runtime_observation_evidence(
	observation: Dictionary,
	wake: Dictionary,
) -> Dictionary:
	var observation_id := String(
		observation.get("observation_id", ""),
	).strip_edges()
	var text := String(observation.get("text", "")).strip_edges()
	if observation_id.is_empty() or text.is_empty():
		return {}
	var source_ref := "runtime_observation:%s" % observation_id
	var snapshot := wake.get("snapshot", {}) as Dictionary
	return _evidence_record(
		text,
		text,
		[],
		[],
		_topics(text),
		snapshot.get("time", {}),
		"firsthand",
		"",
		source_ref,
		[source_ref],
	)


func _event_evidence(event: Dictionary, summary: Dictionary) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var event_type := String(event.get("type", ""))
	var source_ref := "event:%s" % String(event.get("event_id", ""))
	var turns: Array = []
	if event_type in ["搭话", "对方答话", "旁听"]:
		turns = [event.get("turn", {})]
	elif event_type == "对话结束":
		turns = event.get("turns", []) as Array
	if not turns.is_empty():
		for turn_value: Variant in turns:
			if typeof(turn_value) != TYPE_DICTIONARY:
				continue
			var turn := turn_value as Dictionary
			var say := String(turn.get("say", "")).strip_edges()
			var narration := String(turn.get("narration", "")).strip_edges()
			var photo_refs := _turn_photo_refs(turn)
			if say.is_empty() and narration.is_empty() and photo_refs.is_empty():
				continue
			var speaker_id := String(turn.get("speaker_resident_id", ""))
			var speaker_name := String(turn.get("speaker", "")).strip_edges()
			var photo_only := say.is_empty() and narration.is_empty() and not photo_refs.is_empty()
			var subject := "%s说：%s" % [speaker_name, say] if not say.is_empty() else "%s%s" % [speaker_name, narration]
			var topic_text := say if not say.is_empty() else narration
			if photo_only:
				var photo_meaning := _photo_meaning(summary)
				if photo_meaning.is_empty():
					subject = "%s向我展示了一张照片。" % speaker_name
					topic_text = "照片"
				else:
					subject = "%s向我展示的照片显示：%s" % [
						speaker_name,
						photo_meaning,
					]
					topic_text = photo_meaning
			var claim_root := String(
				turn.get("memory_claim_root_id", ""),
			).strip_edges()
			if claim_root.is_empty() and photo_only:
				claim_root = photo_refs[0]
			elif claim_root.is_empty():
				claim_root = "conversation:%s:turn:%d" % [
					String(event.get("conversation_id", "")),
					int(turn.get("turn_id", 0)),
				]
			var evidence_refs: Array = [source_ref, claim_root]
			if photo_only:
				for photo_ref: String in photo_refs:
					if not evidence_refs.has(photo_ref):
						evidence_refs.append(photo_ref)
			var source_kind := "firsthand" if speaker_id == _resident_id or photo_only else "hearsay"
			var spoken_interpretation := _summary_interpretation(summary, subject)
			if not photo_only and not photo_refs.is_empty():
				# The organizer's first current-thought line describes the attached
				# image. Do not also assign that meaning to the speaker's sentence,
				# otherwise the speech trace can steal the photo's semantic match.
				spoken_interpretation = subject
			result.append(_evidence_record(
				subject,
				spoken_interpretation,
				[speaker_id] if not speaker_id.is_empty() else [],
				[],
				_topics(topic_text),
				event.get("time", {}),
				source_kind,
				"" if source_kind == "firsthand" else speaker_id,
				claim_root,
				evidence_refs,
			))
			# A photo attached to spoken text carries two different sources:
			# the speaker's words remain hearsay, while what the resident can see
			# in the image is firsthand evidence. Keep both instead of letting the
			# speech attribution swallow the photo's independent meaning.
			if not photo_only and not photo_refs.is_empty():
				var attached_photo_meaning := _photo_meaning(summary)
				if not attached_photo_meaning.is_empty():
					var attached_refs: Array = [source_ref]
					for photo_ref: String in photo_refs:
						attached_refs.append(photo_ref)
					result.append(_evidence_record(
						"照片显示：%s" % attached_photo_meaning,
						attached_photo_meaning,
						[],
						[],
						_topics(attached_photo_meaning),
						event.get("time", {}),
						"firsthand",
						"",
						photo_refs[0],
						attached_refs,
					))
		return result
	if event_type == "冲突见闻":
		var conflict_summary := String(event.get("summary", "")).strip_edges()
		if conflict_summary.is_empty():
			return result
		var knowledge_kind := String(
			event.get("knowledge_kind", ""),
		).strip_edges()
		var source_resident_id := String(
			event.get("source_resident_id", ""),
		).strip_edges()
		var actor_ids: Array = []
		for actor_id_value: Variant in event.get("actor_ids", []) as Array:
			var actor_id := String(actor_id_value).strip_edges()
			if not actor_id.is_empty() and not actor_ids.has(actor_id):
				actor_ids.append(actor_id)
		var conflict_id := String(event.get("conflict_id", "")).strip_edges()
		var conflict_event_id := String(
			event.get("conflict_event_id", ""),
		).strip_edges()
		var claim_root := "conflict:%s:%s" % [
			conflict_id,
			conflict_event_id,
		]
		var evidence_refs: Array = [source_ref, claim_root]
		result.append(_evidence_record(
			conflict_summary,
			_summary_interpretation(summary, conflict_summary),
			actor_ids,
			[
				String(event.get("place_id", "")).strip_edges(),
			] if not String(event.get("place_id", "")).strip_edges().is_empty() else [],
			_topics(conflict_summary),
			event.get("time", {}),
			"hearsay" if knowledge_kind == "hearsay" else "firsthand",
			source_resident_id if knowledge_kind == "hearsay" else "",
			claim_root,
			evidence_refs,
		))
		return result
	if event_type in ["有人来了", "有人走了"]:
		var who := String(event.get("who", "")).strip_edges()
		var who_resident_id := String(
			event.get("who_resident_id", ""),
		).strip_edges()
		if who.is_empty():
			return result
		var movement_subject := "%s%s" % [
			who,
			"来到我附近。" if event_type == "有人来了" else "离开了我附近。",
		]
		var movement_evidence := _evidence_record(
			movement_subject,
			movement_subject,
			[who_resident_id] if not who_resident_id.is_empty() else [],
			[],
			_topics("%s %s" % [who, event_type]),
			event.get("time", {}),
			"firsthand",
			"",
			source_ref,
			[source_ref],
		)
		# 到来/离开是认知事件，但不应长期占据“正在影响”队列。
		movement_evidence["initial_state"] = "past"
		result.append(movement_evidence)
		return result
	var subject := _event_subject(event)
	if not subject.is_empty():
		var people: Array = []
		for field: String in [
			"who_resident_id",
			"speaker_resident_id",
			"publisher_resident_id",
			"deceased_resident_id",
		]:
			var person := String(event.get(field, ""))
			if not person.is_empty() and not people.has(person):
				people.append(person)
		result.append(_evidence_record(
			subject,
			_summary_interpretation(summary, subject),
			people,
			[String(event.get("place_id", ""))] if not String(event.get("place_id", "")).is_empty() else [],
			_topics(subject),
			event.get("time", {}),
			"hearsay" if event_type in ["公告转告", "正式通知送达"] else "firsthand",
			String(event.get("speaker_resident_id", "")) if event_type in ["公告转告", "正式通知送达"] else "",
			"event:%s" % String(event.get("event_id", "")),
			[source_ref],
		))
	return result


func _turn_photo_refs(turn: Dictionary) -> Array[String]:
	var result: Array[String] = []
	if typeof(turn.get("photos")) != TYPE_ARRAY:
		return result
	for photo_value: Variant in turn.get("photos", []) as Array:
		if typeof(photo_value) != TYPE_DICTIONARY:
			continue
		var photo_ref := String((photo_value as Dictionary).get("ref", "")).strip_edges()
		if not photo_ref.is_empty():
			result.append("photo:%s" % photo_ref)
	return result


func _action_evidence(
	action_result: Dictionary,
	intent: Dictionary,
	wake: Dictionary,
	summary: Dictionary,
) -> Dictionary:
	var action_id := String(action_result.get("action_id", ""))
	var action_type := String(intent.get("type", "动作"))
	var status := String(action_result.get("status", ""))
	var reason := String(action_result.get("reason", "")).strip_edges()
	var subject := "我进行的%s%s" % [action_type, _result_label(status)]
	if not reason.is_empty():
		subject += "：%s" % reason
	var snapshot := wake.get("snapshot", {}) as Dictionary
	return _evidence_record(
		subject,
		_summary_interpretation(summary, subject),
		[],
		[],
		_topics("%s %s" % [subject, JSON.stringify(intent)]),
		(snapshot.get("time", {}) as Dictionary),
		"firsthand",
		"",
		"action:%s" % action_id,
		["action_result:%s" % action_id],
	)


func _merge_evidence(
	entries: Array,
	interventions: Array,
	evidence: Dictionary,
	revision: int,
) -> bool:
	var candidates: Array[int] = _matcher.call("find_candidate_indices", entries, evidence)
	var exact_index := -1
	for index: int in candidates:
		var candidate := entries[index] as Dictionary
		if (
			String(candidate.get("claim_root_id", "")) == String(evidence.get("claim_root_id", ""))
			and String(candidate.get("source_kind", "")) == String(evidence.get("source_kind", ""))
			and String(candidate.get("source_resident_id", "")) == String(evidence.get("source_resident_id", ""))
		):
			exact_index = index
			break
	if exact_index >= 0:
		var exact := entries[exact_index] as Dictionary
		if not _has_new_evidence_ref(exact, evidence):
			# 同一组证据只允许形成一次高阶反思；模型换一种措辞不构成
			# 新证据，也不能借此重复增信或改写已经用于决策的认知节点。
			if String(exact.get("claim_root_id", "")).begins_with("reflection:"):
				return false
			if String(exact.get("subject", "")) != String(evidence.get("subject", "")):
				var active := _active_intervention(
					interventions,
					String(exact.get("memory_id", "")),
				)
				var outcome := String(
					_reappraiser.compare(exact, evidence, active >= 0),
				)
				if outcome != "keep":
					entries[exact_index] = _reappraiser.apply_result(
						exact,
						evidence,
						outcome,
						revision,
					)
					if outcome in ["discover_anomaly", "correct"] and active >= 0:
						var intervention := (
							interventions[active] as Dictionary
						).duplicate(true)
						intervention["status"] = (
							"discovered" if outcome == "discover_anomaly" else "corrected"
						)
						interventions[active] = intervention
					return true
			return _enrich_existing_interpretation(
				entries,
				interventions,
				exact_index,
				evidence,
				revision,
			)
		var active := _active_intervention(interventions, String(exact.get("memory_id", "")))
		var outcome := String(_reappraiser.compare(exact, evidence, active >= 0))
		entries[exact_index] = _reappraiser.apply_result(exact, evidence, outcome, revision)
		if outcome in ["discover_anomaly", "correct"] and active >= 0:
			var intervention := (interventions[active] as Dictionary).duplicate(true)
			intervention["status"] = "discovered" if outcome == "discover_anomaly" else "corrected"
			interventions[active] = intervention
		return true
	for index: int in candidates:
		var candidate := entries[index] as Dictionary
		var active := _active_intervention(interventions, String(candidate.get("memory_id", "")))
		var outcome := String(_reappraiser.compare(candidate, evidence, active >= 0))
		if outcome != "keep":
			entries[index] = _reappraiser.apply_result(candidate, evidence, outcome, revision)
			if outcome in ["discover_anomaly", "correct"] and active >= 0:
				var intervention := (interventions[active] as Dictionary).duplicate(true)
				intervention["status"] = "discovered" if outcome == "discover_anomaly" else "corrected"
				interventions[active] = intervention
			return true
	var memory_id := "memory-%s" % String(AgentJsonScript.content_sha256({
		"resident_id": _resident_id,
		"claim_root_id": evidence.get("claim_root_id", ""),
		"source_kind": evidence.get("source_kind", ""),
		"source_resident_id": evidence.get("source_resident_id", ""),
	})).left(20)
	var created := evidence.duplicate(true)
	var initial_state := String(created.get("initial_state", "influencing"))
	var initial_confidence := int(created.get(
		"initial_confidence",
		78 if String(evidence.get("source_kind", "")) == "firsthand" else 58,
	))
	created.erase("initial_state")
	created.erase("initial_confidence")
	created["memory_id"] = memory_id
	created["resident_id"] = _resident_id
	created["confidence"] = clampi(initial_confidence, 0, 100)
	created["state"] = initial_state
	created["active_version_id"] = "%s-v1" % memory_id
	created["created_revision"] = revision
	created["updated_revision"] = revision
	entries.append(created)
	return true


func _has_new_evidence_ref(entry: Dictionary, evidence: Dictionary) -> bool:
	var existing := entry.get("evidence_refs", []) as Array
	for source_ref: Variant in evidence.get("evidence_refs", []) as Array:
		if not existing.has(source_ref):
			return true
	return false


func _enrich_existing_interpretation(
	entries: Array,
	interventions: Array,
	index: int,
	evidence: Dictionary,
	revision: int,
) -> bool:
	var entry := entries[index] as Dictionary
	var memory_id := String(entry.get("memory_id", ""))
	var incoming := String(evidence.get("interpretation", "")).strip_edges()
	var subject := String(evidence.get("subject", "")).strip_edges()
	if (
		incoming.is_empty()
		or incoming == subject
		or incoming == String(entry.get("interpretation", "")).strip_edges()
		or subject != String(entry.get("subject", "")).strip_edges()
		or String(entry.get("state", "")) in ["anomalous", "corrected"]
		or _active_intervention(interventions, memory_id) >= 0
	):
		return false
	var changed := entry.duplicate(true)
	changed["interpretation"] = incoming.left(480)
	changed["active_version_id"] = "%s-v%d" % [memory_id, revision]
	changed["updated_revision"] = revision
	entries[index] = changed
	return true


func _evidence_record(
	subject: String,
	interpretation: String,
	people: Array,
	places: Array,
	topics: Array,
	world_time: Variant,
	source_kind: String,
	source_resident_id: String,
	claim_root_id: String,
	evidence_refs: Array,
) -> Dictionary:
	return {
		"subject": subject.left(480),
		"interpretation": interpretation.left(480),
		"people": people,
		"places": places,
		"topics": topics,
		"world_time": (world_time as Dictionary).duplicate(true) if typeof(world_time) == TYPE_DICTIONARY else {"day": 1, "clock": "00:00", "period": "清晨"},
		"source_kind": source_kind,
		"source_resident_id": source_resident_id,
		"claim_root_id": claim_root_id,
		"evidence_refs": evidence_refs,
	}


func _event_subject(event: Dictionary) -> String:
	match String(event.get("type", "")):
		"公告发布", "公告阅读", "公告转告", "钟声公告", "正式通知送达":
			return String(event.get("text", "")).strip_edges()
		"营业状态变化":
			return String(event.get("summary", "")).strip_edges()
		"承诺条件变化":
			return String(event.get("summary", "")).strip_edges()
		"身体状况变化":
			return "身体状况：%s" % String(event.get("label", "")).strip_edges()
		"天气变了":
			return "天气变为%s" % String(event.get("weather", "")).strip_edges()
		"居民死亡":
			var death_location := event.get("location", {}) as Dictionary
			return "%s在%s死亡：%s" % [
				String(event.get("deceased_resident_name", "")).strip_edges(),
				String(death_location.get("placeName", "")).strip_edges(),
				String(event.get("reason", "")).strip_edges(),
			]
	return ""


func _summary_interpretation(summary: Dictionary, fallback: String) -> String:
	var important := String(
		summary.get("important_memories", ""),
	).strip_edges()
	if not important.is_empty():
		var speaker_marker := fallback.find("说：")
		if speaker_marker > 0:
			var speaker := fallback.left(speaker_marker).strip_edges()
			for line_value: Variant in important.replace("\r", "\n").split(
				"\n",
				false,
			):
				var line := String(line_value).strip_edges()
				if not speaker.is_empty() and line.contains(speaker):
					# The organizer's text is the resident's own interpretation of
					# this fact. Keep it on the formal entry instead of replacing it
					# with the generic current-thought field; otherwise two residents
					# who witnessed the same event collapse back into one shared fact.
					return line
		# 说话人是本人时,整理文本多以"我"自称,名字匹配不到;
		# 退而按内容相似度在 important_memories 内找归纳行。
		# 解释只能来自 important_memories:current_thoughts 是猜测与情绪,
		# 混入会把无关思绪当成对该事实的理解(跨字段错配)。
		var best_line := ""
		var best_similarity := 0.0
		for line_value: Variant in important.replace("\r", "\n").split(
			"\n",
			false,
		):
			var line := String(line_value).strip_edges()
			var similarity := _text_similarity(fallback, line)
			if similarity > best_similarity:
				best_similarity = similarity
				best_line = line
		if best_similarity >= 0.15:
			return best_line
	return fallback


func _text_similarity(left: String, right: String) -> float:
	var left_grams := _similarity_bigrams(left)
	var right_grams := _similarity_bigrams(right)
	if left_grams.is_empty() or right_grams.is_empty():
		return 0.0
	var shared := 0
	for gram: String in left_grams:
		if right_grams.has(gram):
			shared += 1
	return float(shared * 2) / float(left_grams.size() + right_grams.size())


func _similarity_bigrams(text: String) -> Dictionary:
	var stripped := ""
	for index: int in text.length():
		var character := text[index]
		if character.strip_edges().is_empty():
			continue
		if character in "，。；：、！？,.;:!?“”\"'（）()":
			continue
		stripped += character
	var result: Dictionary = {}
	for index: int in maxi(0, stripped.length() - 1):
		result[stripped.substr(index, 2)] = true
	return result


func _photo_meaning(summary: Dictionary) -> String:
	var current := String(summary.get("current_thoughts", "")).strip_edges()
	for line_value: Variant in current.replace("\r", "\n").split("\n", false):
		var line := String(line_value).strip_edges()
		if not line.is_empty():
			return line.left(360)
	return ""


func _result_label(status: String) -> String:
	match status:
		"completed": return "已经完成"
		"interrupted": return "被中断"
		"rejected": return "没有成功"
		"replaced": return "被新的安排替代"
	return "已有结果"


func _topics(text: String) -> Array:
	var normalized := text
	for separator: String in ["，", "。", "；", "：", ",", ".", ";", ":", "“", "”", " ", "\n"]:
		normalized = normalized.replace(separator, " ")
	var result: Array = []
	for segment_value: Variant in normalized.split(" ", false):
		var segment := String(segment_value).strip_edges()
		if segment.length() < 2:
			continue
		var topic := segment.left(12)
		if not result.has(topic):
			result.append(topic)
		if result.size() >= 8:
			break
	if result.is_empty():
		result.append("经历")
	return result


func _active_intervention(interventions: Array, memory_id: String) -> int:
	for index in range(interventions.size() - 1, -1, -1):
		var intervention := interventions[index] as Dictionary
		if (
			String(intervention.get("memory_id", "")) == memory_id
			and String(intervention.get("status", "")) == "active"
		):
			return index
	return -1
