extends SceneTree
## 巡逻敌人验证 —— 巡逻往返 / 边缘不掉崖 / 撞墙掉头 / 视线追击 / 一击必杀 / 高速不穿墙
## 运行：Godot --headless --path <项目> --script tests/test_patrol.gd
##
## 本测试**不改动** main.tscn，全部用代码搭场景，所以可以放心反复跑。

var _fails: Array[String] = []
var _passes: Array[String] = []

const PATROL := "res://scripts/PatrolEnemy.gd"
const PLAYER := "res://scripts/Player.gd"


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	print("== 巡逻敌人测试开始 ==")

	_test_layer_setup()
	await _test_patrol_patrol_between_bounds()
	await _test_ledge_detection()
	await _test_narrow_pillar_idle()
	await _test_wall_turn()
	await _test_sight_chase()
	await _test_sight_blocked_by_wall()
	await _test_chase_stops_at_ledge()
	await _test_player_kills_moving_enemy()
	await _test_moving_enemy_kills_player()
	await _test_no_tunneling_high_speed()
	await _test_player_passes_through_enemy()
	await _test_respawn_grants_invisible_invincibility()
	await _test_polling_fixes_invisible_invincibility()
	await _test_moving_enemy_death_spiral()
	await _test_slowmo_dash_step_distance()
	await _test_area2d_sees_through_wall()

	Engine.time_scale = 1.0   # 兜底：别让慢动作残留到下一个进程

	for s in _passes:
		push_error("  ✓ " + s)
	for s in _fails:
		push_error("  ✗ " + s)
	if _fails.is_empty():
		push_error("PATROL_OK 通过 %d 项" % _passes.size())
		quit(0)
	else:
		push_error("PATROL_FAIL 失败 %d 项 / 通过 %d 项" % [_fails.size(), _passes.size()])
		quit(1)


# ────────────────────────────── 测试项 ──────────────────────────────

## 物理层设置：层号 vs 位值（最容易踩的配置坑）
func _test_layer_setup() -> void:
	# 复现坑：CharacterBody2D 默认 collision_layer = 1（世界层）
	var naive := CharacterBody2D.new()
	naive.set_collision_layer_value(3, true)   # 只想加"第 3 层 = 敌人"
	var got := naive.collision_layer
	_check(got == 5, "坑的复现：只 set_collision_layer_value(3) 不清零 -> layer = %d（= 世界|敌人，玩家 mask=1 会撞上敌人）" % got)
	naive.free()
	await physics_frame   # 等一帧让物理服务器回收 RID，否则退出时会报 RID 泄漏

	var e := _make_enemy(Vector2(0, 261), -50, 50, false)
	var world := _make_world()
	world.add_child(e)
	await physics_frame
	await physics_frame

	_check(e.collision_layer == 4, "巡逻敌人的 collision_layer = %d（应为 4 = 仅第 3 层 enemy）" % e.collision_layer)
	var danger: Area2D = e.get_node_or_null("Danger")
	_check(danger != null, "Danger 区被自动创建（auto_build_probes = true）")
	if danger:
		_check(danger.collision_mask == 2, "Danger.collision_mask = %d（应为 2 = 第 2 层 player）" % danger.collision_mask)
	var ledge: RayCast2D = e.get_node_or_null("LedgeProbe")
	if ledge:
		_check(ledge.collision_mask == 1, "LedgeProbe.collision_mask = %d（应为 1 = 仅世界层）" % ledge.collision_mask)
	var sight: RayCast2D = e.get_node_or_null("Sight")
	if sight:
		_check(sight.collision_mask == 3, "Sight.collision_mask = %d（应为 3 = 世界|玩家）" % sight.collision_mask)

	world.queue_free()
	await physics_frame


## ① 在两个 x 坐标之间真的来回走，且不越界
func _test_patrol_patrol_between_bounds() -> void:
	var world := _make_world()
	_add_ground(world, Vector2(0, 300), Vector2(1200, 40))
	var e := _make_enemy(Vector2(0, 261), -96.0, 96.0, false)
	world.add_child(e)
	await physics_frame
	for i in range(20):
		await physics_frame
	_check(e.is_on_floor(), "① 敌人落在地面上")

	var min_x := 9999.0
	var max_x := -9999.0
	for i in range(360):
		await physics_frame
		min_x = minf(min_x, e.global_position.x)
		max_x = maxf(max_x, e.global_position.x)

	_check(max_x > 88.0 and max_x < 104.0, "① 走到右边界附近（max_x = %.1f，期望 ≈96）" % max_x)
	_check(min_x < -88.0 and min_x > -104.0, "① 走到左边界附近（min_x = %.1f，期望 ≈-96）" % min_x)

	world.queue_free()
	await physics_frame


## ② 平台边缘检测：巡逻范围远超平台宽度时，必须在崖边掉头而不是掉下去
func _test_ledge_detection() -> void:
	var world := _make_world()
	_add_ground(world, Vector2(0, 300), Vector2(200, 40))   # 半宽 100
	var e := _make_enemy(Vector2(0, 261), -500.0, 500.0, false)
	world.add_child(e)
	await physics_frame

	var min_x := 9999.0
	var max_x := -9999.0
	var fell := false
	for i in range(300):
		await physics_frame
		min_x = minf(min_x, e.global_position.x)
		max_x = maxf(max_x, e.global_position.x)
		if e.global_position.y > 340.0:
			fell = true
			break

	_check(not fell and e.is_on_floor(), "② 没有掉下平台（is_on_floor = %s，y = %.0f）" % [e.is_on_floor(), e.global_position.y])
	_check(max_x < 100.0, "② 最远只走到 %.0f（平台右边缘 100，不会走出去）" % max_x)
	_check(max_x > 60.0, "② 确实走到了接近边缘的位置（max_x = %.0f，说明边缘检测没过度保守）" % max_x)
	_check(min_x < -60.0, "② 另一侧也走到了边缘（min_x = %.0f）" % min_x)

	world.queue_free()
	await physics_frame


## ③ 站在比身体还窄的柱子上：两侧都没地面 -> 站住不动，不要抽筋
func _test_narrow_pillar_idle() -> void:
	var world := _make_world()
	_add_ground(world, Vector2(0, 300), Vector2(24, 40))   # 半宽 12 < 探针前伸 15
	var e := _make_enemy(Vector2(0, 261), -500.0, 500.0, false)
	world.add_child(e)
	await physics_frame
	for i in range(10):
		await physics_frame
	var x0 := e.global_position.x
	for i in range(90):
		await physics_frame
	var moved := absf(e.global_position.x - x0)

	_check(moved < 2.0, "③ 窄柱子上原地站住（90 帧位移 %.2f px，状态 %s）" % [moved, e.get_state_name()])
	_check(e.is_on_floor() or e.global_position.y > 300.0, "③ 没有在半空中抖动（y = %.1f）" % e.global_position.y)

	world.queue_free()
	await physics_frame


## ④ 撞墙掉头
func _test_wall_turn() -> void:
	var world := _make_world()
	_add_ground(world, Vector2(0, 300), Vector2(1200, 40))
	_add_wall(world, Vector2(150, 261), Vector2(20, 100))
	var e := _make_enemy(Vector2(0, 261), -500.0, 500.0, false)
	world.add_child(e)
	await physics_frame

	var max_x := -9999.0
	for i in range(260):
		await physics_frame
		max_x = maxf(max_x, e.global_position.x)

	var final_x := e.global_position.x
	_check(max_x < 135.0, "④ 被墙挡住（max_x = %.1f，墙左边缘 140 - 半身 13 = 127 左右）" % max_x)
	_check(max_x > 100.0, "④ 确实走到了墙前（max_x = %.1f）" % max_x)
	_check(final_x < max_x - 20.0, "④ 撞墙后掉头往回走（final_x = %.1f < max_x = %.1f）" % [final_x, max_x])

	world.queue_free()
	await physics_frame


## ⑤ 视线追击：同一水平线上无遮挡 -> 进入 CHASE 并靠近
func _test_sight_chase() -> void:
	var world := _make_world()
	_add_ground(world, Vector2(0, 300), Vector2(1400, 40))
	var e := _make_enemy(Vector2(0, 261), -30.0, 30.0, true)
	e.set("sight_distance", 200.0)
	world.add_child(e)
	var p := _make_player_stub(Vector2(150, 261), world)
	await physics_frame

	var saw := false
	for i in range(30):
		await physics_frame
		if e.get_state_name() == "CHASE":
			saw = true
			break
	_check(saw, "⑤ 玩家在正前方 150px -> 进入 CHASE（状态 %s）" % e.get_state_name())

	var d0 := absf(e.global_position.x - p.global_position.x)
	for i in range(60):
		await physics_frame
	var d1 := absf(e.global_position.x - p.global_position.x)
	_check(d1 < d0 - 40.0, "⑤ 朝玩家靠近（距离 %.0f -> %.0f）" % [d0, d1])

	world.queue_free()
	await physics_frame


## ⑥ 隔墙不该发现玩家（Area2D 方案的经典 bug）
func _test_sight_blocked_by_wall() -> void:
	var world := _make_world()
	_add_ground(world, Vector2(0, 300), Vector2(1400, 40))
	_add_wall(world, Vector2(80, 261), Vector2(20, 100))
	var e := _make_enemy(Vector2(0, 261), -30.0, 30.0, true)
	e.set("sight_distance", 200.0)
	world.add_child(e)
	_make_player_stub(Vector2(150, 261), world)
	await physics_frame

	var chased := false
	for i in range(60):
		await physics_frame
		if e.get_state_name() == "CHASE":
			chased = true
			break
	_check(not chased, "⑥ 中间隔一堵墙 -> 不会发现玩家（状态 %s）" % e.get_state_name())

	world.queue_free()
	await physics_frame


## ⑦ 追击时也要做边缘检测，否则会为了追你跳崖自尽
func _test_chase_stops_at_ledge() -> void:
	var world := _make_world()
	_add_ground(world, Vector2(0, 300), Vector2(200, 40))   # 半宽 100，敌人必须停在崖边
	var e := _make_enemy(Vector2(0, 261), -500.0, 500.0, true)
	e.set("sight_distance", 400.0)
	world.add_child(e)
	_make_player_stub(Vector2(300, 261), world)             # 玩家悬在平台外的空中
	await physics_frame

	for i in range(200):
		await physics_frame

	_check(e.is_on_floor(), "⑦ 追击时没有跳下平台（y = %.1f）" % e.global_position.y)
	_check(e.global_position.x < 105.0, "⑦ 刹在崖边（x = %.1f）" % e.global_position.x)
	_check(e.get_state_name() == "CHASE", "⑦ 仍然处于追击状态（没有莫名放弃）")

	world.queue_free()
	await physics_frame


## ⑧ 玩家砍死"正在移动"的敌人（一击必杀 + 移动）
func _test_player_kills_moving_enemy() -> void:
	var world := _make_world()
	_add_ground(world, Vector2(0, 300), Vector2(1200, 40))
	# 敌人在 45~75 之间来回走（相对出生点 ±15），玩家的攻击框罩住这段区间
	var e := _make_enemy(Vector2(60, 261), -15.0, 15.0, false)
	world.add_child(e)
	var p := _make_player(Vector2(10, 261), world)
	await physics_frame
	for i in range(30):
		await physics_frame

	# 确认敌人真的在动（不是站着不动的靶子）
	var mn := 9999.0
	var mx := -9999.0
	for i in range(40):
		await physics_frame
		mn = minf(mn, e.global_position.x)
		mx = maxf(mx, e.global_position.x)
	var span := mx - mn
	_check(span > 8.0, "⑧ 敌人确实在移动（40 帧内 x 跨度 %.1f px）" % span)
	_check(not p.get("_is_dead"), "⑧ 玩家还没死（危险区没碰到玩家）")

	Input.action_press("attack")
	await physics_frame
	await physics_frame
	Input.action_release("attack")
	for i in range(20):
		await physics_frame

	# 敌人被击杀后会 tween 淡出再 queue_free，所以此刻它可能已经不在树里了
	var gone := not is_instance_valid(e)
	_check(gone or e.is_dead(), "⑧ 移动中的敌人被一击必杀（%s）" % ("已释放" if gone else "dead = %s" % e.is_dead()))

	world.queue_free()
	await physics_frame


## ⑨ 移动的敌人撞死玩家（Danger 区）
func _test_moving_enemy_kills_player() -> void:
	var world := _make_world()
	_add_ground(world, Vector2(0, 300), Vector2(1200, 40))
	var e := _make_enemy(Vector2(80, 261), -70.0, 70.0, false)
	world.add_child(e)
	var p := _make_player(Vector2(0, 261), world)
	await physics_frame
	for i in range(20):
		await physics_frame

	var died := false
	for i in range(180):
		await physics_frame
		if p.get("_is_dead"):
			died = true
			break
	_check(died, "⑨ 敌人走过来碰到玩家 -> 玩家死亡（敌人 x = %.1f，玩家 x = %.1f）" % [e.global_position.x, p.global_position.x])

	world.queue_free()
	await physics_frame


## ⑩ 高速移动不穿墙（move_and_slide 是扫掠式的）
func _test_no_tunneling_high_speed() -> void:
	var world := _make_world()
	_add_wall(world, Vector2(0, 261), Vector2(20, 200))
	var body := CharacterBody2D.new()
	body.collision_layer = 0
	body.set_collision_layer_value(6, true)
	body.collision_mask = 0
	body.set_collision_mask_value(1, true)
	var cs := CollisionShape2D.new()
	var rs := RectangleShape2D.new()
	rs.size = Vector2(26, 34)
	cs.shape = rs
	body.add_child(cs)
	body.global_position = Vector2(-300, 261)
	world.add_child(body)
	await physics_frame

	body.velocity = Vector2(6000.0, 0.0)   # 6000 px/s = 每物理帧 100px，墙只有 20px 厚
	for i in range(30):
		body.velocity = Vector2(6000.0, 0.0)
		body.move_and_slide()
		await physics_frame

	_check(body.global_position.x < -10.0, "⑩ 6000px/s 也没穿过 20px 厚的墙（x = %.1f）" % body.global_position.x)

	world.queue_free()
	await physics_frame


## ⑪ 玩家不会被敌人身体挡住（玩家 mask 只有世界层）
func _test_player_passes_through_enemy() -> void:
	var world := _make_world()
	_add_ground(world, Vector2(0, 300), Vector2(1200, 40))
	var e := _make_enemy(Vector2(60, 261), -10.0, 10.0, false)
	e.set("patrol_speed", 0.0)      # 站着不动，专门验证"不是一堵墙"
	world.add_child(e)
	var p := _make_player(Vector2(-120, 261), world)
	await physics_frame
	for i in range(20):
		await physics_frame
	e.get_node("Danger").monitoring = false   # 关掉危险区，只看有没有被挡住

	Input.action_press("move_right")
	for i in range(70):
		await physics_frame
	Input.action_release("move_right")

	_check(p.global_position.x > 70.0, "⑪ 玩家穿过了敌人身体（x = %.1f，敌人在 %.1f）" % [p.global_position.x, e.global_position.x])

	world.queue_free()
	await physics_frame


## ⑫ 【危险】只靠 body_entered 时：站着不动的敌人占住检查点，第一次死，之后**不再死**
##
## Area2D 的 body_entered 只在"重叠状态从无到有"的那一帧发一次。
## 玩家 respawn 到敌人身体上时，重叠状态**从来没变化过**（一直重叠），
## 所以不会再有 entered 信号 —— 玩家反而获得"隐形无敌"。
## 这里刻意把 danger_polling 关掉，还原"只靠信号"的写法。
func _test_respawn_grants_invisible_invincibility() -> void:
	var world := _make_world()
	_add_ground(world, Vector2(0, 300), Vector2(1200, 40))
	var e := _make_enemy(Vector2(0, 261), 0.0, 0.0, false)   # 站着不动，一直占住检查点
	e.set("danger_polling", false)                          # 只靠 body_entered 信号
	world.add_child(e)
	var p := _make_player(Vector2(-200, 261), world)
	await physics_frame
	for i in range(20):
		await physics_frame
	_check(not p.get("_is_dead"), "⑫ 前置：玩家在远处安全")

	p.respawn(Vector2(0, 261))   # 模拟"检查点正好在敌人身上"
	var deaths := 0
	for i in range(120):
		await physics_frame
		if p.get("_is_dead"):
			deaths += 1
			p.respawn(Vector2(0, 261))   # 每次死了立刻回来（Main.gd 现在的行为）

	_check(deaths == 1, "⑫ 只靠 entered：站敌人身上 respawn 只判死 %d 次，之后再也不触发（隐形无敌）" % deaths)
	_check(not p.get("_is_dead"), "⑫ 玩家此刻活着，而且就站在敌人身体里（危险区已失效）")

	world.queue_free()
	await physics_frame


## ⑭ 开着 danger_polling（默认）时，同样的场景不会再出现隐形无敌
func _test_polling_fixes_invisible_invincibility() -> void:
	var world := _make_world()
	_add_ground(world, Vector2(0, 300), Vector2(1200, 40))
	var e := _make_enemy(Vector2(0, 261), 0.0, 0.0, false)   # danger_polling 默认 true
	world.add_child(e)
	var p := _make_player(Vector2(-200, 261), world)
	await physics_frame
	for i in range(20):
		await physics_frame

	p.respawn(Vector2(0, 261))
	var deaths := 0
	for i in range(120):
		await physics_frame
		if p.get("_is_dead"):
			deaths += 1
			p.respawn(Vector2(0, 261))

	_check(deaths >= 3, "⑭ 每帧轮询：站在敌人身上会持续判死（120 帧内 %d 次），没有隐形无敌" % deaths)

	world.queue_free()
	await physics_frame


## ⑮ 会移动的敌人占住检查点 -> 真正的死亡螺旋（每秒都在死）
func _test_moving_enemy_death_spiral() -> void:
	var world := _make_world()
	_add_ground(world, Vector2(0, 300), Vector2(1600, 40))
	var e := _make_enemy(Vector2(-120, 261), 0.0, 240.0, false)   # 从 -120 往右巡逻，必定扫过 x=0
	world.add_child(e)
	var p := _make_player(Vector2(400, 261), world)
	await physics_frame
	for i in range(20):
		await physics_frame

	# 检查点设在敌人巡逻路线上（x=0），玩家复活后不动 -> 敌人每次扫过来都会撞死他
	p.respawn(Vector2(0, 261))
	var deaths := 0
	for i in range(400):
		await physics_frame
		if p.get("_is_dead"):
			deaths += 1
			p.respawn(Vector2(0, 261))
	_check(deaths >= 3, "⑮ 会移动的敌人 + 检查点在它巡逻路线上 -> 400 帧内死了 %d 次（死亡螺旋）" % deaths)

	# 对策：Main.gd 在复活瞬间用 set_danger_enabled(false) 给玩家一个"重生保护窗口"
	e.set_danger_enabled(false)
	p.respawn(Vector2(0, 261))
	var deaths_in_grace := 0
	for i in range(30):
		await physics_frame
		if p.get("_is_dead"):
			deaths_in_grace += 1
			p.respawn(Vector2(0, 261))
	_check(deaths_in_grace == 0, "⑮ set_danger_enabled(false) 的重生保护窗口内不再判死（%d 次）" % deaths_in_grace)

	e.set_danger_enabled(true)
	await physics_frame
	await physics_frame

	# 兜底：敌人回位 + 玩家回安全点，彻底不再连环死
	e.reset_enemy()
	p.respawn(Vector2(400, 261))
	var after := 0
	for i in range(120):
		await physics_frame
		if p.get("_is_dead"):
			after += 1
			p.respawn(Vector2(400, 261))
	_check(after == 0, "⑮ reset_enemy() + 复活到安全点 -> 120 帧内不再死亡（%d 次）" % after)

	world.queue_free()
	await physics_frame


## ⑯ 子弹时间下的冲刺单帧位移 —— 决定"危险区要做多宽"才不漏检
func _test_slowmo_dash_step_distance() -> void:
	var world := _make_world()
	_add_ground(world, Vector2(0, 300), Vector2(4000, 40))
	var p := _make_player(Vector2(-1500, 261), world)
	await physics_frame
	for i in range(30):
		await physics_frame

	# 正常速度下冲刺的单帧位移
	Input.action_press("dash")
	await physics_frame
	await physics_frame
	var x0 := p.global_position.x
	await physics_frame
	var step_normal := absf(p.global_position.x - x0)
	Input.action_release("dash")
	await physics_frame

	# 子弹时间下（time_scale -> 0.3）冲刺的单帧位移
	Input.action_press("slow")
	for i in range(40):
		await physics_frame
	var ts: float = Engine.time_scale
	Input.action_press("dash")
	await physics_frame
	await physics_frame
	var x1 := p.global_position.x
	await physics_frame
	var step_slow := absf(p.global_position.x - x1)
	Input.action_release("dash")
	Input.action_release("slow")
	Engine.time_scale = 1.0

	_check(step_slow < 20.0, "⑯ 子弹时间(time_scale=%.2f)下冲刺单帧位移 = %.1f px（没被放大 -> 危险区不用为慢动作加宽）" % [ts, step_slow])
	_check(step_normal < 20.0, "⑯ 正常速度下冲刺单帧位移 = %.1f px（危险区宽 30px，安全余量足够）" % step_normal)

	world.queue_free()
	await physics_frame


# ────────────────────────────── 搭场景的工具 ──────────────────────────────

func _make_world() -> Node2D:
	var w := Node2D.new()
	w.name = "TestWorld"
	root.add_child(w)
	return w


func _add_ground(parent: Node, center: Vector2, size: Vector2) -> StaticBody2D:
	var b := StaticBody2D.new()
	b.collision_layer = 0
	b.set_collision_layer_value(1, true)   # 第 1 层 = 世界
	b.collision_mask = 0
	var cs := CollisionShape2D.new()
	var rs := RectangleShape2D.new()
	rs.size = size
	cs.shape = rs
	b.add_child(cs)
	b.position = center
	parent.add_child(b)
	return b


func _add_wall(parent: Node, center: Vector2, size: Vector2) -> StaticBody2D:
	return _add_ground(parent, center, size)


## 造一个巡逻敌人（只给 Shape + Visual，探针和 Danger 交给 auto_build_probes 自动补）
func _make_enemy(at: Vector2, left: float, right: float, chase: bool) -> CharacterBody2D:
	var e := CharacterBody2D.new()
	e.set_script(load(PATROL))
	e.set("patrol_left", left)
	e.set("patrol_right", right)
	e.set("can_chase", chase)
	e.position = at

	var shape := CollisionShape2D.new()
	shape.name = "Shape"
	var rect := RectangleShape2D.new()
	rect.size = Vector2(26, 34)
	shape.shape = rect
	e.add_child(shape)

	var vis := ColorRect.new()
	vis.name = "Visual"
	vis.offset_left = -13.0
	vis.offset_top = -17.0
	vis.offset_right = 13.0
	vis.offset_bottom = 17.0
	vis.color = Color(0.85, 0.32, 0.32, 1.0)
	e.add_child(vis)
	return e


## 真实 Player.gd 的玩家（AttackArea / Shape 名字必须和 Player.gd 的 @onready 对上）
func _make_player(at: Vector2, parent: Node) -> CharacterBody2D:
	var p := CharacterBody2D.new()
	p.set_script(load(PLAYER))
	p.collision_layer = 0
	p.set_collision_layer_value(2, true)
	p.collision_mask = 0
	p.set_collision_mask_value(1, true)
	p.position = at

	var shape := CollisionShape2D.new()
	shape.name = "Shape"
	var rect := RectangleShape2D.new()
	rect.size = Vector2(18, 30)
	shape.shape = rect
	p.add_child(shape)

	var vis := ColorRect.new()
	vis.name = "Visual"
	vis.offset_left = -9.0
	vis.offset_top = -15.0
	vis.offset_right = 9.0
	vis.offset_bottom = 15.0
	p.add_child(vis)

	var aa := Area2D.new()
	aa.name = "AttackArea"
	aa.position = Vector2(33, 0)
	aa.monitoring = false
	aa.collision_layer = 0
	aa.set_collision_mask_value(3, true)   # 只检测第 3 层 = enemy
	var ash := CollisionShape2D.new()
	ash.name = "Shape"
	var ar := RectangleShape2D.new()
	ar.size = Vector2(52, 34)
	ash.shape = ar
	aa.add_child(ash)
	p.add_child(aa)

	parent.add_child(p)
	return p


## 玩家的"靶子"替身：只用来被视线射线看到，不跑任何脚本
func _make_player_stub(at: Vector2, parent: Node) -> CharacterBody2D:
	var p := CharacterBody2D.new()
	p.collision_layer = 0
	p.set_collision_layer_value(2, true)
	p.collision_mask = 0
	p.add_to_group("player")
	p.position = at
	var cs := CollisionShape2D.new()
	var rs := RectangleShape2D.new()
	rs.size = Vector2(18, 30)
	cs.shape = rs
	p.add_child(cs)
	parent.add_child(p)
	return p


## ⑰ 为什么视线检测该用 RayCast2D：同一位置放个 Area2D 感知区，隔墙也能"看到"玩家
func _test_area2d_sees_through_wall() -> void:
	var world := _make_world()
	_add_ground(world, Vector2(0, 300), Vector2(1400, 40))
	_add_wall(world, Vector2(80, 261), Vector2(20, 100))

	var e := _make_enemy(Vector2(0, 261), -30.0, 30.0, true)
	e.set("sight_distance", 200.0)
	world.add_child(e)
	_make_player_stub(Vector2(150, 261), world)

	# 在敌人身上再挂一个大范围 Area2D 感知区（只检测玩家层），模拟"用 Area2D 做视野"
	var sense := Area2D.new()
	sense.collision_layer = 0
	sense.collision_mask = 0
	sense.set_collision_mask_value(2, true)
	var ss := CollisionShape2D.new()
	var sr := RectangleShape2D.new()
	sr.size = Vector2(400.0, 60.0)
	ss.shape = sr
	sense.add_child(ss)
	e.add_child(sense)

	await physics_frame
	await physics_frame
	await physics_frame

	_check(sense.has_overlapping_bodies(),
		"⑰ Area2D 感知区隔着一堵墙也检测到玩家（重叠 %d 个）—— 它没有「遮挡」概念" % sense.get_overlapping_bodies().size())
	_check(e.get_state_name() != "CHASE",
		"⑰ 同一位置的 RayCast2D 视线被墙挡住 -> 不追击（状态 %s）" % e.get_state_name())

	world.queue_free()
	await physics_frame


func _check(cond: bool, label: String) -> void:
	if cond:
		_passes.append(label)
	else:
		_fails.append(label)
