class_name TownProviderCredentialStore
extends RefCounted


const RESULT_SHAPES := preload(
	"res://world/contract/TownWorldResultShapes.gd"
)
const PROVIDER_STORE_FILES := preload(
	"res://world/presentation/ui/TownProviderStoreFiles.gd"
)
const DEFAULT_PATH := "user://provider_credentials.enc"
const WEB_DEVICE_ID_PATH := "user://provider_credentials.web_device_id"
const SCHEMA_VERSION := 1
const CREDENTIAL_NAMESPACE := "ai-town.provider-credentials.v1"

var _path := DEFAULT_PATH


func configure(path: Variant = DEFAULT_PATH) -> Dictionary:
	if typeof(path) != TYPE_STRING:
		return _failure("PROVIDER_CREDENTIAL_PATH_INVALID")
	var candidate := path as String
	if candidate != candidate.strip_edges() or not _user_storage_path_is_valid(candidate):
		return _failure("PROVIDER_CREDENTIAL_PATH_INVALID")
	_path = candidate
	return _success()


func load_keys() -> Dictionary:
	var password_result := _encryption_password()
	if not bool(password_result.get("ok", false)):
		return password_result
	var password := String(password_result.get("password", ""))
	var backup_path := "%s.bak" % _path
	_remove_file_if_present("%s.tmp" % _path)
	if not FileAccess.file_exists(_path):
		if FileAccess.file_exists(backup_path):
			return _restore_backup(backup_path, password)
		return _success({"keys": {}})
	var loaded := _read_validated_keys(_path, password)
	if bool(loaded.get("ok", false)):
		_remove_file_if_present(backup_path)
		return loaded
	if not FileAccess.file_exists(backup_path):
		return loaded
	var recovered := _restore_backup(backup_path, password)
	return recovered if bool(recovered.get("ok", false)) else loaded


func save_api_key(provider_id_value: Variant, api_key_value: Variant) -> Dictionary:
	if (
		typeof(provider_id_value) != TYPE_STRING
		or typeof(api_key_value) != TYPE_STRING
	):
		return _failure("PROVIDER_API_KEY_REQUIRED")
	var provider_id := provider_id_value as String
	var api_key := api_key_value as String
	if not _provider_id_is_valid(provider_id) or not _api_key_is_valid(api_key):
		return _failure("PROVIDER_API_KEY_REQUIRED")
	var loaded := load_keys()
	if not bool(loaded.get("ok", false)):
		return loaded
	var keys := (loaded.get("keys", {}) as Dictionary).duplicate(true)
	keys[provider_id] = api_key
	var persisted := _save_keys(keys)
	if not bool(persisted.get("ok", false)):
		return persisted
	return _success({"apiKeyRef": _key_ref(provider_id)})


func delete_api_key(provider_id_value: Variant) -> Dictionary:
	if typeof(provider_id_value) != TYPE_STRING:
		return _failure("PROVIDER_SETTINGS_PROVIDER_REQUIRED")
	var provider_id := provider_id_value as String
	if not _provider_id_is_valid(provider_id):
		return _failure("PROVIDER_SETTINGS_PROVIDER_REQUIRED")
	var loaded := load_keys()
	if not bool(loaded.get("ok", false)):
		return loaded
	var keys := (loaded.get("keys", {}) as Dictionary).duplicate(true)
	var changed := keys.erase(provider_id)
	if not changed:
		return _success({"changed": false})
	if keys.is_empty():
		var cleared := clear()
		if not bool(cleared.get("ok", false)):
			return cleared
		return _success({"changed": true})
	var persisted := _save_keys(keys)
	if not bool(persisted.get("ok", false)):
		return persisted
	return _success({"changed": true})


func api_key(provider_id_value: Variant) -> Dictionary:
	if typeof(provider_id_value) != TYPE_STRING:
		return _failure("PROVIDER_SETTINGS_PROVIDER_REQUIRED")
	var provider_id := provider_id_value as String
	if not _provider_id_is_valid(provider_id):
		return _failure("PROVIDER_SETTINGS_PROVIDER_REQUIRED")
	var loaded := load_keys()
	if not bool(loaded.get("ok", false)):
		return loaded
	var key_value: Variant = (loaded.get("keys", {}) as Dictionary).get(
		provider_id,
		"",
	)
	var key := key_value as String
	return _success({
		"apiKey": key,
		"apiKeyRef": _key_ref(provider_id) if not key.is_empty() else "",
		"saved": not key.is_empty(),
	})


func clear() -> Dictionary:
	var changed := false
	for candidate: String in [_path, "%s.tmp" % _path, "%s.bak" % _path]:
		if not FileAccess.file_exists(candidate):
			continue
		var error := DirAccess.remove_absolute(
			ProjectSettings.globalize_path(candidate)
		)
		if error != OK:
			return _failure("PROVIDER_CREDENTIAL_DELETE_FAILED")
		changed = true
	return _success({"changed": changed})


func _save_keys(keys: Dictionary) -> Dictionary:
	var validation := _validate_keys(keys)
	if not bool(validation.get("ok", false)):
		return validation
	var password_result := _encryption_password()
	if not bool(password_result.get("ok", false)):
		return password_result
	var password := String(password_result.get("password", ""))
	var temporary_path := "%s.tmp" % _path
	var backup_path := "%s.bak" % _path
	_remove_file_if_present(temporary_path)
	var file := FileAccess.open_encrypted_with_pass(
		temporary_path,
		FileAccess.WRITE,
		password,
	)
	if file == null:
		return _failure("PROVIDER_CREDENTIAL_WRITE_FAILED")
	file.store_string(JSON.stringify({
		"schemaVersion": SCHEMA_VERSION,
		"keys": keys.duplicate(true),
	}))
	file.flush()
	var write_error := file.get_error()
	file = null
	if write_error != OK:
		_remove_file_if_present(temporary_path)
		return _failure("PROVIDER_CREDENTIAL_WRITE_FAILED")
	var written := _read_validated_keys(temporary_path, password)
	if (
		not bool(written.get("ok", false))
		or written.get("keys", {}) != keys
	):
		_remove_file_if_present(temporary_path)
		return _failure("PROVIDER_CREDENTIAL_WRITE_VALIDATION_FAILED")
	var replaced := _replace_validated_file(
		temporary_path,
		_path,
		backup_path,
	)
	if replaced != OK:
		_remove_file_if_present(temporary_path)
		return _failure("PROVIDER_CREDENTIAL_WRITE_FAILED")
	return _success()


func _read_validated_keys(path: String, password: String) -> Dictionary:
	var probe := FileAccess.open(path, FileAccess.READ)
	if probe == null:
		return _failure("PROVIDER_CREDENTIAL_READ_FAILED")
	var magic := probe.get_buffer(4)
	probe = null
	if magic != "GDEC".to_ascii_buffer():
		return _failure("PROVIDER_CREDENTIAL_READ_FAILED")
	var file := FileAccess.open_encrypted_with_pass(
		path,
		FileAccess.READ,
		password,
	)
	if file == null:
		return _failure("PROVIDER_CREDENTIAL_READ_FAILED")
	var content := file.get_as_text()
	var read_error := file.get_error()
	file = null
	if read_error != OK:
		return _failure("PROVIDER_CREDENTIAL_READ_FAILED")
	var parsed: Variant = JSON.parse_string(content)
	if not parsed is Dictionary:
		return _failure("PROVIDER_CREDENTIAL_INVALID")
	var payload := parsed as Dictionary
	if (
		payload.size() != 2
		or not payload.has("schemaVersion")
		or not payload.has("keys")
	):
		return _failure("PROVIDER_CREDENTIAL_INVALID")
	var schema_value: Variant = payload.get("schemaVersion")
	if (
		typeof(schema_value) == TYPE_FLOAT
		and is_finite(float(schema_value))
		and float(schema_value) == float(SCHEMA_VERSION)
	):
		payload["schemaVersion"] = SCHEMA_VERSION
		schema_value = SCHEMA_VERSION
	if (
		typeof(schema_value) != TYPE_INT
		or int(schema_value) != SCHEMA_VERSION
	):
		return _failure("PROVIDER_CREDENTIAL_SCHEMA_UNSUPPORTED")
	var keys_value: Variant = payload.get("keys")
	if not keys_value is Dictionary:
		return _failure("PROVIDER_CREDENTIAL_INVALID")
	var validation := _validate_keys(keys_value as Dictionary)
	if not bool(validation.get("ok", false)):
		return validation
	return _success({
		"keys": (keys_value as Dictionary).duplicate(true),
	})


func _validate_keys(keys: Dictionary) -> Dictionary:
	for provider_id_value: Variant in keys.keys():
		if (
			typeof(provider_id_value) != TYPE_STRING
			or not _provider_id_is_valid(provider_id_value as String)
		):
			return _failure("PROVIDER_CREDENTIAL_INVALID")
		var key_value: Variant = keys.get(provider_id_value)
		if (
			typeof(key_value) != TYPE_STRING
			or not _api_key_is_valid(key_value as String)
			or key_value != (key_value as String).strip_edges()
		):
			return _failure("PROVIDER_CREDENTIAL_INVALID")
	return _success()


func _restore_backup(backup_path: String, password: String) -> Dictionary:
	var backup := _read_validated_keys(backup_path, password)
	if not bool(backup.get("ok", false)):
		return _failure("PROVIDER_CREDENTIAL_RECOVERY_FAILED")
	_remove_file_if_present(_path)
	var restore_error := DirAccess.rename_absolute(
		ProjectSettings.globalize_path(backup_path),
		ProjectSettings.globalize_path(_path),
	)
	if restore_error != OK:
		return _failure("PROVIDER_CREDENTIAL_RECOVERY_FAILED")
	return backup


func _replace_validated_file(
	temporary_path: String,
	final_path: String,
	backup_path: String,
) -> Error:
	return PROVIDER_STORE_FILES.replace_validated_file(temporary_path, final_path, backup_path)


func _encryption_password() -> Dictionary:
	var device_id := ""
	if OS.has_feature("web"):
		var web_device_id := _load_or_create_web_device_id(WEB_DEVICE_ID_PATH)
		if not bool(web_device_id.get("ok", false)):
			return web_device_id
		device_id = String(web_device_id.get("deviceId", ""))
	else:
		device_id = OS.get_unique_id().strip_edges()
	if device_id.is_empty():
		return _failure("PROVIDER_CREDENTIAL_DEVICE_ID_UNAVAILABLE")
	var project_name := String(
		ProjectSettings.get_setting("application/config/name", "ai-town")
	).strip_edges()
	var password := (
		"%s|%s|%s" % [CREDENTIAL_NAMESPACE, project_name, device_id]
	).sha256_text()
	return _success({"password": password})


func _load_or_create_web_device_id(path: String) -> Dictionary:
	if FileAccess.file_exists(path):
		var existing_file := FileAccess.open(path, FileAccess.READ)
		if existing_file == null:
			return _failure("PROVIDER_CREDENTIAL_DEVICE_ID_UNAVAILABLE")
		var existing_id := existing_file.get_as_text().strip_edges()
		var read_error := existing_file.get_error()
		existing_file = null
		if read_error != OK or not _web_device_id_is_valid(existing_id):
			return _failure("PROVIDER_CREDENTIAL_DEVICE_ID_UNAVAILABLE")
		return _success({"deviceId": existing_id})

	var random_bytes := Crypto.new().generate_random_bytes(32)
	if random_bytes.size() != 32:
		return _failure("PROVIDER_CREDENTIAL_DEVICE_ID_UNAVAILABLE")
	var generated_id := random_bytes.hex_encode()
	var temporary_path := "%s.tmp" % path
	_remove_file_if_present(temporary_path)
	var temporary_file := FileAccess.open(temporary_path, FileAccess.WRITE)
	if temporary_file == null:
		return _failure("PROVIDER_CREDENTIAL_DEVICE_ID_UNAVAILABLE")
	temporary_file.store_string(generated_id)
	temporary_file.flush()
	var write_error := temporary_file.get_error()
	temporary_file = null
	if write_error != OK:
		_remove_file_if_present(temporary_path)
		return _failure("PROVIDER_CREDENTIAL_DEVICE_ID_UNAVAILABLE")
	var rename_error := DirAccess.rename_absolute(
		ProjectSettings.globalize_path(temporary_path),
		ProjectSettings.globalize_path(path),
	)
	if rename_error != OK:
		_remove_file_if_present(temporary_path)
		return _failure("PROVIDER_CREDENTIAL_DEVICE_ID_UNAVAILABLE")
	return _success({"deviceId": generated_id})


func _web_device_id_is_valid(device_id: String) -> bool:
	if device_id.length() != 64:
		return false
	for character: String in device_id:
		if character not in "0123456789abcdef":
			return false
	return true


func _provider_id_is_valid(provider_id: String) -> bool:
	if provider_id.is_empty() or provider_id != provider_id.strip_edges():
		return false
	for character: String in provider_id:
		if character not in "0123456789abcdefghijklmnopqrstuvwxyz-_":
			return false
	return true


func _api_key_is_valid(api_key: String) -> bool:
	if api_key.is_empty() or api_key != api_key.strip_edges():
		return false
	for character: String in api_key:
		var codepoint := character.unicode_at(0)
		if codepoint < 32 or codepoint == 127:
			return false
	return true


func _user_storage_path_is_valid(path: String) -> bool:
	return PROVIDER_STORE_FILES.user_storage_path_is_valid(path)


func _remove_file_if_present(path: String) -> void:
	PROVIDER_STORE_FILES.remove_file_if_present(path)


func _key_ref(provider_id: String) -> String:
	return "secure_store.llm.%s.api_key" % provider_id


func _success(extra: Dictionary = {}) -> Dictionary:
	return RESULT_SHAPES.success_with(extra)


func _failure(error_code: String) -> Dictionary:
	return RESULT_SHAPES.failure(error_code)
