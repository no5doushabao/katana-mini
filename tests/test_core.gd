extends SceneTree
## 核心机制验证 —— 跳跃 / 攻击击杀 / 一击必杀 / 重开
## 运行：Godot --headless --path <项目> --script tests/test_core.gd
##
## 两个踩过的坑，写在这里免得重踩：
##   1. 注入输入后必须等 2 个物理帧：第 1 帧只记录按键，第 2 帧 just_pressed 才为 true
##   2. 动态造节点时，必须先把整棵子树搭好，最后才 add_child 进树——
##      否则 _ready 会在子节点还没挂上时就执行，$Danger 拿到 null

var _fails: Array[String] = []
var _passes: Array[String] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var packed: PackedScene = load("res://main.tscn")
	var scene: Node = packed.instantiate()
	root.add_child(scene)

	var p: CharacterBody2D = scene.get_node("Player") as CharacterBody2D

	# ── 找第一个静止敌人 ──
	# ⚠️ 不能写死 Enemies/Enemy1：地图是生成的，节点名会随布局变。
	#    从 "enemy" 组里挑第一个非 CharacterBody2D 的（= 静止靶子；巡逻兵是 CharacterBody2D）。
	var e: Node2D = null
	for n in get_nodes_in_group("enemy"):
		if not (n is CharacterBody2D):
			e = n as Node2D
			break
	# 兜底：实在找不到就随便取一个
	if e == null and get_nodes_in_group("enemy").size() > 0:
		e = get_nodes_in_group("enemy")[0] as Node2D

	if e == null:
		_fails.append("★ 地图里找不到任何敌人")
		_finish()
		return

	# ── 准备：等玩家落到地面 ──
	for i in range(120):
		await physics_frame
		if i > 10 and p.is_on_floor():
			break
	_check(p.is_on_floor(), "玩家落到地面")

	# 挪到敌人左侧 55px。
	# ⚠️ 这个偏移量是有讲究的：太近（<40）会站在敌人身上被撞死；
	#    太远（>59）攻击框够不到。55 落在安全命中窗口内。
	p.global_position = Vector2(e.global_position.x - 55.0, e.global_position.y)
	p.velocity = Vector2.ZERO
	for i in range(12):
		await physics_frame

	# ── 1. 跳跃 ──
	Input.action_press("jump")
	await physics_frame
	await physics_frame
	var vy: float = p.velocity.y
	Input.action_release("jump")
	_check(vy < -100.0, "跳跃生效（velocity.y = %.1f）" % vy)
	# 等它落回地面再继续（否则后面"接触判死"的测试会被空中的状态干扰）
	for i in range(120):
		await physics_frame
		if i > 5 and p.is_on_floor():
			break

	# 回到攻击位置（跳跃可能让玩家漂移）
	p.global_position = Vector2(e.global_position.x - 55.0, e.global_position.y)
	p.velocity = Vector2.ZERO
	for i in range(12):
		await physics_frame

	# ── 2. 攻击击杀敌人（必须在"一击必杀"测试之前，否则玩家已经死了）──
	# 注意：用 _alive_enemies() 而不是 get_nodes_in_group().size()——
	# 敌人死后不再从场景/组里移除（为了能被检查点复位找回），见 _alive_enemies 的注释。
	var before := _alive_enemies()
	_check(before >= 1, "敌人在场（%d 个活着的）" % before)

	var died_fired := [false]
	e.died.connect(func() -> void: died_fired[0] = true)

	Input.action_press("attack")
	await physics_frame
	await physics_frame
	Input.action_release("attack")
	for i in range(20):
		await physics_frame

	var after := _alive_enemies()
	_check(after < before, "攻击击杀敌人（活着 %d -> %d）" % [before, after])
	_check(died_fired[0], "died 信号已发出（HUD 计分会更新）")

	# ── 3. 一击必杀：新敌人压在玩家身上 ──
	var lives_before: int = scene.get("lives")
	var pos_before_death := p.global_position
	var probe := _make_probe(p.global_position)
	scene.get_node("Enemies").add_child(probe)

	for i in range(30):
		await physics_frame

	var lives_after: int = scene.get("lives")
	_check(lives_after > lives_before, "一击必杀生效（死亡 %d -> %d）" % [lives_before, lives_after])

	# ── 4. 死亡后自动回检查点 ──
	# 注意：检查点通常在"地面之上一点"，玩家回去后会继续下落到地面 —— 这是对的。
	# 所以断言看"是否被传回去了"，不看落点 y。
	# 阈值取 60px：足以区分"被送回检查点"和"还在原地"，又不会被落地漂移干扰。
	for i in range(90):
		await physics_frame
		if i > 5 and p.is_on_floor():
			break
	var cp: Vector2 = scene.get("checkpoint")
	var moved_back := absf(p.global_position.x - cp.x) < 8.0
	var was_far := absf(pos_before_death.x - cp.x) > 60.0
	_check(was_far and moved_back,
		"重开机制生效（x 从 %.0f 回到检查点 %.0f）" % [pos_before_death.x, cp.x])

	# ── 5. 攻击框跟随朝向（用户实测发现的 bug：转身时框不跟着转）──
	# 根因曾经是：攻击框位置更新被写在 `if _attack_left > 0.0:` 里面，
	# 所以只有攻击那 0.1 秒内才更新，平时冻在旧位置。
	var aa := scene.get_node_or_null("Player/AttackArea") as Area2D
	if aa == null:
		_fails.append("⑤ 找不到 AttackArea")
	else:
		# 强制朝右，看框是否在右侧
		Input.action_press("move_right")
		await physics_frame
		if absf(p.velocity.x) < 1.0:
			await physics_frame
		await physics_frame
		Input.action_release("move_right")
		var f_right: int = p.get("facing")
		var x_right: float = aa.position.x
		_check(f_right == 1 and x_right > 0.0,
			"⑤a 朝右时攻击框在右侧（facing=%d, box.x=%.1f）" % [f_right, x_right])

		# 强制朝左，看框是否跟着到左侧
		Input.action_press("move_left")
		await physics_frame
		if absf(p.velocity.x) < 1.0:
			await physics_frame
		await physics_frame
		Input.action_release("move_left")
		var f_left: int = p.get("facing")
		var x_left: float = aa.position.x
		_check(f_left == -1 and x_left < 0.0,
			"⑤b 转身后攻击框跟到左侧（facing=%d, box.x=%.1f）" % [f_left, x_left])
		if f_left == -1 and x_left > 0.0:
			_fails.append("   ↳ ★ 攻击框没跟随转身（这就是用户发现的 bug）")

		# ⑤c 垂直居中：碰撞判定的 y 必须为 0（不许有偏移）
		#    曾经有个 bug 是"画"出来的框没居中（朝右偏下 17px），
		#    虽然判定本身是对的，但会误导判断，所以这里钉死它。
		_check(absf(aa.position.y) < 0.001,
			"⑤c 攻击框垂直居中（AttackArea.y=%.2f，两种朝向都应为 0）" % aa.position.y)

		# ⑤d 两种朝向的垂直位置一致（水平镜像，y 完全对称）
		Input.action_press("move_right")
		await physics_frame
		await physics_frame
		Input.action_release("move_right")
		var y_r: float = aa.position.y
		_check(absf(y_r - aa.position.y) < 0.001 or absf(y_r) < 0.001,
			"⑤d 朝右/朝左时攻击框高度一致（y 差 %.2f）" % absf(y_r - aa.position.y))

	# ── 掉出世界底部 = 死（用户 2026-10-07）──
	#
	# 没有这条判定的话，掉进沟里会**永远坠落**：死不了、也回不来，只能自己按 R ——
	# 那不是"不够合理"，是**卡死状态**；而且它会让屏 2 那条 110px 深沟
	# （"冲刺要收得住"的教学）变成纯装饰。
	# ⚠️ 阈值从 Main.gd 的常量读，不写死数字（以后调地图高度不该让测试假失败）。
	var levels := get_nodes_in_group("level")
	if levels.is_empty():
		_fails.append("★ 找不到 level 组节点（Main.gd 没注册？）")
	else:
		var lc: Dictionary = (levels[0] as Node).get_script().get_script_constant_map()
		var fall_y: float = float(lc.get("FALL_DEATH_Y", 0.0))
		_check(fall_y > 0.0, "关卡定义了掉落死亡阈值（FALL_DEATH_Y=%.0f）" % fall_y)

		# 阈值必须**明显低于地面**，否则站在地上就会被判死
		_check(fall_y > 480.0 + 80.0,
			"掉落阈值在地面之下留有余量（%.0f > 地面顶 480 + 80）—— 否则正常跳跃会误伤" % fall_y)

		p.respawn(Vector2(120.0, 400.0))
		await physics_frame
		_check(not p.get("_is_dead"), "复活后是活的（前置条件）")

		p.global_position = Vector2(p.global_position.x, fall_y + 30.0)
		for i in range(4):
			await physics_frame
		_check(p.get("_is_dead"), "掉到阈值以下会判定死亡（不再无限坠落）")

		# 收尾：把人放回地面，别给后面的断言留脏状态
		p.respawn(Vector2(120.0, 400.0))
		await physics_frame

	# ── 汇总（统一走 _finish，避免和"提前 return"路径重复实现）──
	_finish()


## 造一个完整的敌人节点树（返回时尚未进树，调用方负责 add_child）
func _make_probe(at: Vector2) -> Node2D:
	var probe := Node2D.new()
	probe.set_script(load("res://scripts/Enemy.gd"))
	probe.position = at

	var body := StaticBody2D.new()
	body.name = "Body"
	body.collision_layer = 4
	body.collision_mask = 0
	var bs := CollisionShape2D.new()
	bs.name = "Shape"
	var br := RectangleShape2D.new()
	br.size = Vector2(26, 34)
	bs.shape = br
	body.add_child(bs)
	probe.add_child(body)

	var danger := Area2D.new()
	danger.name = "Danger"
	danger.collision_layer = 0
	danger.collision_mask = 2
	var ds := CollisionShape2D.new()
	ds.name = "Shape"
	var dr := RectangleShape2D.new()
	dr.size = Vector2(40, 44)
	ds.shape = dr
	danger.add_child(ds)
	probe.add_child(danger)

	return probe


func _check(cond: bool, label: String) -> void:
	if cond:
		_passes.append(label)
	else:
		_fails.append(label)


## 数"活着的敌人"
##
## ⚠️ 不能再用 get_nodes_in_group("enemy").size() 判断击杀：
##    为了让"检查点复位"在复活时能把敌人找回来，敌人死后**不再 queue_free**、
##    也**不从组里移除**（否则复位逻辑永远找不到它）。
##    所以死活必须问 is_dead()。
func _alive_enemies() -> int:
	var n := 0
	for e in get_nodes_in_group("enemy"):
		if e.has_method("is_dead") and e.is_dead():
			continue
		n += 1
	return n


## 统一收尾：打印结果并退出
## （抽出来是为了"提前 return"的路径也能正常汇报，而不是静默退出）
func _finish() -> void:
	for s in _passes:
		push_error("  ✓ " + s)
	for s in _fails:
		push_error("  ✗ " + s)
	if _fails.is_empty():
		push_error("CORE_OK 通过 %d 项" % _passes.size())
		quit(0)
	else:
		push_error("CORE_FAIL 失败 %d 项 / 通过 %d 项" % [_fails.size(), _passes.size()])
		quit(1)
