class_name WebTextInputBridge
extends RefCounted


signal text_changed(text: String)
signal cancel_requested


const ELEMENT_ATTRIBUTE := "data-ai-town-web-input"
const DEFAULT_FONT_FAMILY := (
	'"PingFang SC", "Noto Sans CJK SC", "Microsoft YaHei", sans-serif'
)


var _control: Control
var _element: Variant
var _input_callback: Variant
var _keydown_callback: Variant
var _max_chars := 0


func open(control: Control, text: String, options: Dictionary = {}) -> bool:
	close()
	if not OS.has_feature("web") or not is_instance_valid(control):
		return false
	var document: Variant = JavaScriptBridge.get_interface("document")
	if document == null:
		return false
	var canvas: Variant = document.getElementById("canvas")
	if canvas == null:
		return false
	_control = control
	_max_chars = maxi(int(options.get("maxChars", 0)), 0)
	_element = document.createElement("textarea")
	if _element == null:
		_control = null
		return false
	_element.setAttribute(ELEMENT_ATTRIBUTE, String(options.get("id", "text")))
	_element.setAttribute("aria-label", String(options.get("ariaLabel", "文本输入")))
	_element.setAttribute("autocomplete", "off")
	_element.setAttribute("autocapitalize", "off")
	_element.setAttribute("spellcheck", "false")
	_element.setAttribute("lang", String(options.get("language", "zh-CN")))
	_element.setAttribute("inputmode", "text")
	_element.value = _limit(text)
	var style: Variant = _element.style
	style.setProperty("position", "fixed")
	style.setProperty("z-index", "2147483646")
	style.setProperty("box-sizing", "border-box")
	style.setProperty("resize", "none")
	style.setProperty("overflow", "auto")
	style.setProperty("outline", "none")
	style.setProperty("letter-spacing", "0")
	style.setProperty("font-family", String(options.get("fontFamily", DEFAULT_FONT_FAMILY)))
	style.setProperty("font-weight", "400")
	style.setProperty("line-height", "1.5")
	style.setProperty("color", String(options.get("color", "#55361f")))
	style.setProperty("caret-color", String(options.get("caretColor", "#b64b2d")))
	style.setProperty("background", String(options.get("background", "#f8dca2")))
	style.setProperty("border", String(options.get("border", "2px solid #dc9829")))
	style.setProperty("border-radius", "0")
	style.setProperty("padding", String(options.get("padding", "12px")))
	style.setProperty("margin", "0")
	style.setProperty("pointer-events", "auto")
	_input_callback = JavaScriptBridge.create_callback(_on_input)
	_keydown_callback = JavaScriptBridge.create_callback(_on_keydown)
	_element.addEventListener("input", _input_callback)
	_element.addEventListener("keydown", _keydown_callback)
	document.body.appendChild(_element)
	refresh_rect()
	_element.focus()
	var end := String(_element.value).length()
	_element.setSelectionRange(end, end)
	return true


func close() -> void:
	if _element != null:
		if _input_callback != null:
			_element.removeEventListener("input", _input_callback)
		if _keydown_callback != null:
			_element.removeEventListener("keydown", _keydown_callback)
		_element.remove()
	_element = null
	_input_callback = null
	_keydown_callback = null
	_control = null
	_max_chars = 0


func is_open() -> bool:
	return _element != null


func focus() -> void:
	if _element != null:
		_element.focus()


func get_text() -> String:
	if _element == null:
		return ""
	return _limit(String(_element.value))


func set_text(value: String) -> void:
	if _element == null:
		return
	var limited := _limit(value)
	if String(_element.value) != limited:
		_element.value = limited


func refresh_rect() -> void:
	if _element == null or not is_instance_valid(_control):
		return
	var document: Variant = JavaScriptBridge.get_interface("document")
	if document == null:
		return
	var canvas: Variant = document.getElementById("canvas")
	if canvas == null:
		return
	var canvas_dom_rect: Variant = canvas.getBoundingClientRect()
	var canvas_rect := Rect2(
		float(canvas_dom_rect.left),
		float(canvas_dom_rect.top),
		float(canvas_dom_rect.width),
		float(canvas_dom_rect.height),
	)
	var viewport_size := _control.get_viewport_rect().size
	var css_rect := scaled_css_rect(
		_control.get_global_rect(),
		viewport_size,
		canvas_rect,
	).grow(-2.0)
	if css_rect.size.x <= 0.0 or css_rect.size.y <= 0.0:
		return
	var scale := minf(
		canvas_rect.size.x / maxf(viewport_size.x, 1.0),
		canvas_rect.size.y / maxf(viewport_size.y, 1.0),
	)
	var font_size := maxf(float(_control.get_theme_font_size("font_size")) * scale, 16.0)
	var style: Variant = _element.style
	style.setProperty("left", _pixels(css_rect.position.x))
	style.setProperty("top", _pixels(css_rect.position.y))
	style.setProperty("width", _pixels(css_rect.size.x))
	style.setProperty("height", _pixels(css_rect.size.y))
	style.setProperty("font-size", _pixels(font_size))


static func scaled_css_rect(
	control_rect: Rect2,
	viewport_size: Vector2,
	canvas_rect: Rect2,
) -> Rect2:
	if viewport_size.x <= 0.0 or viewport_size.y <= 0.0:
		return Rect2()
	var scale := Vector2(
		canvas_rect.size.x / viewport_size.x,
		canvas_rect.size.y / viewport_size.y,
	)
	return Rect2(
		canvas_rect.position + control_rect.position * scale,
		control_rect.size * scale,
	)


func _on_input(_arguments: Array) -> void:
	if _element == null:
		return
	var current := String(_element.value)
	var limited := _limit(current)
	if limited != current:
		_element.value = limited
	text_changed.emit(limited)


func _on_keydown(arguments: Array) -> void:
	if arguments.is_empty():
		return
	var event: Variant = arguments[0]
	if event == null:
		return
	if String(event.key) == "Escape" and not bool(event.isComposing):
		event.preventDefault()
		cancel_requested.emit()


func _limit(value: String) -> String:
	if _max_chars <= 0 or value.length() <= _max_chars:
		return value
	return value.left(_max_chars)


func _pixels(value: float) -> String:
	return "%.2fpx" % value
