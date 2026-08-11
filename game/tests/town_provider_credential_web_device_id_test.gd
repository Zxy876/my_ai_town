extends SceneTree


const CREDENTIAL_STORE := preload(
	"res://world/presentation/ui/TownProviderCredentialStore.gd"
)

var _failures: Array[String] = []
var _checks := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var suffix := "%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	var device_id_path := (
		"user://tests/provider_credentials/web_device_id_%s" % suffix
	)
	var absolute_parent := ProjectSettings.globalize_path(device_id_path).get_base_dir()
	_expect(
		DirAccess.make_dir_recursive_absolute(absolute_parent) in [OK, ERR_ALREADY_EXISTS],
		"测试目录可创建",
	)
	var store: RefCounted = CREDENTIAL_STORE.new()
	var created := (
		store.call("_load_or_create_web_device_id", device_id_path) as Dictionary
	)
	_expect(bool(created.get("ok", false)), "浏览器设备编号可生成")
	var first_id := String(created.get("deviceId", ""))
	_expect(first_id.length() == 64, "浏览器设备编号为 256 位随机值")
	var loaded := (
		store.call("_load_or_create_web_device_id", device_id_path) as Dictionary
	)
	_expect(bool(loaded.get("ok", false)), "浏览器设备编号可读取")
	_expect(String(loaded.get("deviceId", "")) == first_id, "浏览器设备编号保持稳定")

	var corrupt_file := FileAccess.open(device_id_path, FileAccess.WRITE)
	_expect(corrupt_file != null, "损坏夹具可写入")
	if corrupt_file != null:
		corrupt_file.store_string("invalid")
		corrupt_file = null
	var corrupt := (
		store.call("_load_or_create_web_device_id", device_id_path) as Dictionary
	)
	_expect(not bool(corrupt.get("ok", false)), "损坏的浏览器设备编号不会静默替换")
	_expect(
		String(corrupt.get("errorCode", ""))
		== "PROVIDER_CREDENTIAL_DEVICE_ID_UNAVAILABLE",
		"损坏的浏览器设备编号返回稳定错误码",
	)

	store = null
	DirAccess.remove_absolute(ProjectSettings.globalize_path(device_id_path))
	DirAccess.remove_absolute(absolute_parent)
	var audio := root.get_node_or_null("TownAudioController")
	if audio != null and audio.has_method("prepare_shutdown"):
		audio.call("prepare_shutdown")
	for _index in 5:
		await process_frame
	await create_timer(0.3, true, false, true).timeout
	if _failures.is_empty():
		print("TOWN_PROVIDER_CREDENTIAL_WEB_DEVICE_ID_PASS checks=%d" % _checks)
		quit(0)
		return
	for failure: String in _failures:
		printerr("TOWN_PROVIDER_CREDENTIAL_WEB_DEVICE_ID_FAIL: %s" % failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures.append(message)
