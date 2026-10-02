extends SceneTree
## 平台可达性测试 + 关卡连通性
##
## 补上曾经让我翻车的测试缺口：
##   早先的 test_core 只测了"玩家能落地"，没测"能不能真的跳到平台上"，
##   结果关卡里有跳不上去的平台也一路绿灯。
##
## ⚠️ 两个反复踩到的坑，写在这里免得重犯：
##  1) 跳跃键必须**按住约 18 帧**。Player.gd 有可变跳跃高度（松手 velocity.y *= 0.45），
##     按 1~2 帧就松会把跳跃砍半，得到"跳不上去"的假结论。
##  2) 起跳点有**成功窗口**。实测平台0（左边缘 530、顶面 429）：
##       起跳 380 → 落点 514 ❌（撞在平台左侧壁）
##       起跳 440 → 落点 538 ✅
##       起跳 500 → 落点 578 ✅
##     也就是起跳点要落在「平台左边缘左侧约 30~100px」这个区间里。


func _initialize() -> void:
	_run.call_deferred()


func _adv(frames: int) -> void:
	for i in range(frames):
		await physics_frame


## 完整高度起跳（按住跳覆盖上升期，落地即松方向键）
func _jump_full(p: CharacterBody2D, dir: String = "") -> void:
	if dir != "":
		Input.action_press(dir)
		await _adv(40)
	Input.action_press("jump")
	await physics_frame
	await physics_frame
	await _adv(18)
	Input.action_release("jump")
	for i in range(150):
		await physics_frame
		if i > 3 and p.is_on_floor():
			break
	if dir != "":
		Input.action_release(dir)
	await _adv(10)


## 关掉所有敌人的危险区 —— 测跳跃时不该被敌人干扰
func _danger_off() -> void:
	for e in get_nodes_in_group("enemy"):
		var dg: Area2D = e.get_node_or_null("Danger") as Area2D
		if dg:
			dg.set_deferred("monitoring", false)


func _run() -> void:
	Engine.time_scale = 1.0
	var packed: PackedScene = load("res://main.tscn")
	var scene: Node = packed.instantiate()
	root.add_child(scene)
	var p: CharacterBody2D = scene.get_node("Player") as CharacterBody2D

	var ground_top: float = 480.0
	var stand_y: float = ground_top - 15.0

	var fails: Array[String] = []
	var oks: Array[String] = []

	await _adv(120)
	if p.is_on_floor():
		oks.append("玩家初始落在地面（y=%.1f）" % p.global_position.y)
	else:
		fails.append("★ 玩家没落到地面（y=%.1f）" % p.global_position.y)

	# ── 量一次真实满跳高度 ──
	var y0: float = p.global_position.y
	Input.action_press("jump")
	await physics_frame
	await physics_frame
	var peak: float = p.global_position.y
	for i in range(40):
		await physics_frame
		peak = minf(peak, p.global_position.y)
		if p.velocity.y >= 0.0:
			break
	Input.action_release("jump")
	var jump_h: float = y0 - peak
	await _adv(90)
	if jump_h > 55.0:
		oks.append("玩家满跳高度 = %.1f px" % jump_h)
	else:
		fails.append("★ 满跳高度只有 %.1f px（太低了）" % jump_h)

	# ── 逐个平台测可达性 ──
	_danger_off()
	await _adv(5)

	var solids := scene.get_node_or_null("Solids")
	var tested := 0
	if solids:
		for child in solids.get_children():
			if not (child is StaticBody2D):
				continue
			var body := child as StaticBody2D
			if not body.name.begins_with("Platform"):
				continue
			tested += 1
			var plat_top: float = body.global_position.y - 11.0
			var on_y: float = plat_top - 15.0
			var need_h: float = stand_y - plat_top
			# 起跳点要按"平台有多高"自动前移：
			#   跳得越高，到达平台高度时水平飞得越近 —— 起跳点就得越靠左。
			#   基准是实测出来的：36px 高时中心-180 刚好（起跳点≈中心-64）。
			#   _jump_full 会先助跑 40 帧（约 116px），所以这里写的是**加速前的起点**。
			var margin: float = 180.0 + (need_h - 36.0) * 8.0
			p.global_position = Vector2(body.global_position.x - margin, stand_y)
			p.velocity = Vector2.ZERO
			await _adv(30)
			# 关掉危险物：本测试只验证"跳不跳得上"。
			# 被 Hazard 扫到而死是**关卡设计**的事，不该让可达性测试失败。
			for hz in get_nodes_in_group("hazard"):
				(hz as Area2D).set_deferred("monitoring", false)
			await physics_frame
			await _jump_full(p, "move_right")   # ★ 必须传方向！默认空串=只原地跳
			for hz in get_nodes_in_group("hazard"):
				(hz as Area2D).set_deferred("monitoring", true)
			# 判定范围按平台实际半宽来（不写死数字）
			var half_w: float = 90.0
			var cs := body.get_node_or_null("Shape") as CollisionShape2D
			if cs and cs.shape is RectangleShape2D:
				half_w = (cs.shape as RectangleShape2D).size.x * 0.5
			var on: bool = p.is_on_floor() and absf(p.global_position.y - on_y) < 16.0 \
				and absf(p.global_position.x - body.global_position.x) < half_w + 20.0
			if on:
				oks.append("%s 可达（需跳 %.0f px）→ 落点 %s" % [
					body.name, need_h, str(p.global_position.round())])
			else:
				fails.append("★ %s 不可达（需跳 %.0f px，满跳 %.0f px）→ 落点 %s" % [
					body.name, need_h, jump_h, str(p.global_position.round())])

	if tested == 0:
		fails.append("★ 一个平台都没测到")
	else:
		oks.append("共测 %d 个平台" % tested)

	# ── 站立敌人应贴在地面 ──
	for e in get_nodes_in_group("enemy"):
		var n2 := e as Node2D
		if n2 == null or n2 is CharacterBody2D:
			continue
		if absf(n2.global_position.y - (ground_top - 17.0)) > 8.0:
			fails.append("★ 静止敌人 %s 没贴地（y=%.1f）" % [n2.name, n2.global_position.y])
		else:
			oks.append("静止敌人 %s 贴地（y=%.1f）" % [n2.name, n2.global_position.y])

	for s in oks:
		push_error("  ✓ " + s)
	for s in fails:
		push_error("  ✗ " + s)
	if fails.is_empty():
		push_error("REACH_OK 平台全部可达（%d 项）" % oks.size())
	else:
		push_error("REACH_FAIL 失败 %d 项 / 通过 %d 项" % [fails.size(), oks.size()])
	quit(0 if fails.is_empty() else 1)
