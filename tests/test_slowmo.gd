extends SceneTree
## 子弹时间验证
## ⚠️ Engine.time_scale 是全局状态，异常退出会残留——所以用 _finish() 统一收尾
##
## 另一个坑：time_scale 变小后，物理帧的"墙钟时间"变长，
## 所以要按 Engine.time_scale 折算需要的帧数，不能写死。

var _fails: Array[String] = []
var _passes: Array[String] = []


func _initialize() -> void:
	_run.call_deferred()


## 推进指定"游戏内秒数"。
## ⚠️ 坑：物理帧按墙钟时间触发，但每帧推进的游戏时间 = (1/60) × time_scale。
## 所以想推进 N 游戏秒，不能简单地等 N 秒墙钟——必须把帧数折算出来。
## 更稳的做法是直接用 _advance_frames()，避免折算公式引入的类型/时序误差。
func _advance(game_seconds: float) -> void:
	var frames := int(ceil(game_seconds * 60.0 / maxf(Engine.time_scale, 0.05)))
	for i in range(frames):
		await physics_frame


## 按物理帧数推进 —— 时序可控，推荐在慢动作测试里用这个
func _advance_frames(frames: int) -> void:
	for i in range(frames):
		await physics_frame


func _finish() -> void:
	Engine.time_scale = 1.0   # ★ 必须恢复，否则污染之后的运行
	for s in _passes:
		push_error("  ✓ " + s)
	for s in _fails:
		push_error("  ✗ " + s)
	if _fails.is_empty():
		push_error("SLOW_OK 通过 %d 项" % _passes.size())
		quit(0)
	else:
		push_error("SLOW_FAIL 失败 %d 项 / 通过 %d 项" % [_fails.size(), _passes.size()])
		quit(1)


func _run() -> void:
	var packed: PackedScene = load("res://main.tscn")
	var scene: Node = packed.instantiate()
	root.add_child(scene)
	var p: CharacterBody2D = scene.get_node("Player")

	for i in range(60):
		await physics_frame

	# ── 1. 输入映射存在且绑定了键 ──
	var has_action := InputMap.has_action("slow")
	_check(has_action, "slow 动作已注册")
	if has_action:
		var evs := InputMap.action_get_events("slow")
		var key_desc := []
		for e in evs:
			if e is InputEventKey:
				key_desc.append(str(e.physical_keycode))
		_check(evs.size() > 0, "slow 已绑定按键（physical_keycode = %s）" % ", ".join(key_desc))
	else:
		_fails.append("slow 动作不存在，跳过绑定检查")

	# ── 2. 初始状态：时间正常 ──
	_check(absf(Engine.time_scale - 1.0) < 0.001, "初始 time_scale = %.2f" % Engine.time_scale)
	var energy_max: float = p.get("SLOW_ENERGY_MAX")
	_check(absf(p.get("_slow_energy") - energy_max) < 0.01,
		"能量初始满值（%.2f / %.2f）" % [p.get("_slow_energy"), energy_max])

	# ── 3. 按住 Shift -> 进入子弹时间 ──
	Input.action_press("slow")
	await _advance(0.8)

	var ts: float = Engine.time_scale
	_check(ts < 0.5, "按住 Shift 后 time_scale 降到 %.3f（目标 0.30）" % ts)
	_check(p.get("_slow_energy") < energy_max,
		"能量在消耗（%.2f / %.2f）" % [p.get("_slow_energy"), energy_max])

	# ── 4. 玩家速度补偿是否生效 ──
	var comp: float = p.call("_time_compensation")
	_check(comp > 2.0, "玩家速度补偿系数 = %.2f（世界慢 %.0f%%，玩家相对变快）" % [comp, ts * 100.0])

	# 实测位移：按住右键在慢动作里移动，看实际速度
	var x0: float = p.global_position.x
	Input.action_press("move_right")
	await _advance(0.25)
	var dx: float = p.global_position.x - x0
	Input.action_release("move_right")
	# 0.25 游戏秒，补偿后速度 = SPEED / time_scale，位移大约 = SPEED * 0.25 / time_scale
	var expected: float = p.get("SPEED") * 0.25 / maxf(ts, 0.05)
	_check(dx > 100.0, "慢动作中实际位移 %.1f 像素（约 %.1f 屏幕像素/游戏秒）" % [dx, dx / 0.25])

	# ── 5. 松开 Shift -> 恢复 ──
	Input.action_release("slow")
	await _advance(1.0)
	_check(Engine.time_scale > 0.9, "松开后 time_scale 恢复到 %.3f" % Engine.time_scale)

	# ── 6. 能量耗尽后自动退出 ──
	# 直接推进足够多帧，不纠结"折算成多少游戏秒"——
	# 诊断实测：time_scale=0.3 时约 290 帧耗尽 1.6 能量，这里给 500 帧留足余量。
	Input.action_press("slow")
	await _advance_frames(500)
	var drained: float = p.get("_slow_energy")
	Input.action_release("slow")
	_check(drained <= 0.01, "能量被耗尽（剩余 %.3f）" % drained)
	await _advance_frames(120)   # 等平滑过渡走完
	_check(Engine.time_scale > 0.9,
		"能量耗尽后自动退出慢动作（time_scale = %.2f）" % Engine.time_scale)

	# ── 7. 能量会恢复 ──
	await _advance(1.5)
	_check(p.get("_slow_energy") > drained, "停用后能量回升（%.2f -> %.2f）" % [drained, p.get("_slow_energy")])

	_finish()


func _check(cond: bool, label: String) -> void:
	if cond:
		_passes.append(label)
	else:
		_fails.append(label)
