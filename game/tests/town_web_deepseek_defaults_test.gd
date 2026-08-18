extends SceneTree


const DEEPSEEK_PROVIDER := preload(
	"res://agent/model/DeepSeekModelProvider.gd"
)
const SETTINGS_SERVICE := preload(
	"res://world/presentation/ui/TownProviderSettingsService.gd"
)

var _failures: Array[String] = []
var _checks := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var provider: RefCounted = DEEPSEEK_PROVIDER.new()
	_expect(
		String(provider.call("_web_proxy_endpoint", "https://town.example/"))
		== "https://town.example/api/deepseek/chat/completions",
		"Web DeepSeek 使用同源代理地址",
	)
	_expect(
		String(provider.call("_web_proxy_endpoint", "javascript:invalid")).is_empty(),
		"Web DeepSeek 拒绝非 HTTP 来源",
	)

	var service: RefCounted = SETTINGS_SERVICE.new()
	service.set("_stored_config", {
		"schemaVersion": 1,
		"selectedProviderId": "",
		"selectedModelByProvider": {},
		"providers": {},
	})
	service.set("_credential_keys", {})
	service.call("_apply_web_proxy_defaults", true)
	var stored := service.get("_stored_config") as Dictionary
	_expect(
		String(stored.get("selectedProviderId", "")) == "deepseek",
		"Web 首次运行默认选择 DeepSeek",
	)
	_expect(
		String((stored.get("selectedModelByProvider", {}) as Dictionary).get("deepseek", ""))
		== "deepseek-v4-flash",
		"Web 首次运行默认选择 DeepSeek 模型",
	)
	var runtime_configs := (
		service.call("_provider_configs_for_runtime") as Dictionary
	)
	var deepseek_runtime := runtime_configs.get("deepseek", {}) as Dictionary
	_expect(
		String(deepseek_runtime.get("api_key", ""))
		== "ai-town-web-server-managed",
		"Web 运行时只使用无密钥的服务器托管标记",
	)
	_expect(
		not deepseek_runtime.has("endpoint"),
		"Web 默认地址由 DeepSeek Provider 同源解析",
	)
	var actions := service.call("_actions", {
		"selectedProviderId": "deepseek",
		"providers": [{"providerId": "deepseek"}],
	}) as Dictionary
	_expect(
		not bool((actions.get("saveKey", {}) as Dictionary).get("enabled", true)),
		"服务器托管模式不向玩家索要密钥",
	)
	_expect(
		not bool((actions.get("saveBaseUrl", {}) as Dictionary).get("enabled", true)),
		"服务器托管模式不允许覆盖代理地址",
	)

	provider = null
	service = null
	var audio := root.get_node_or_null("TownAudioController")
	if audio != null and audio.has_method("prepare_shutdown"):
		audio.call("prepare_shutdown")
	for _index in 5:
		await process_frame
	await create_timer(0.3, true, false, true).timeout
	if _failures.is_empty():
		print("TOWN_WEB_DEEPSEEK_DEFAULTS_PASS checks=%d" % _checks)
		quit(0)
		return
	for failure: String in _failures:
		printerr("TOWN_WEB_DEEPSEEK_DEFAULTS_FAIL: %s" % failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures.append(message)
