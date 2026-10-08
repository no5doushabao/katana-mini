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

	# ── 木桩 ≠ 精英（2026-10-08 阿包拍板：「木桩是木桩，精英是精英，有本质区别」）──
	# 这几条专防"静默失效"：贴图加载失败时 load() 返回 null **而且不报错**（§8.1 老坑），
	# 木桩/精英的开关要是接错，外观和伤害都会悄悄串味、但测试全绿。
	#
	# ⚠️ 位置有讲究：这几条带 `await` 的等待（共 60 帧），放在**跳跃测试之前**会让
	#    玩家在地面上多站 1 秒，跳跃那两条就变得不稳（实测挂了一次："velocity.y = 0.0"）。
	#    最基础的跳跃先跑，这批"关卡配置"断言放它后面。
	var dummy: Node = null
	var real_elite: Node = null
	for el in get_nodes_in_group("elite"):
		if bool(el.get("is_dummy")):
			dummy = el
		else:
			real_elite = el
	_check(dummy != null, "关卡里有 1 个木桩（无限血沙包，专门用来试元素反应）")
	_check(real_elite != null, "关卡里有 1 个真精英（砍 4 刀死、会伤人 —— 中伤害档的唯一来源）")
	if dummy != null and real_elite != null:
		var dvis := dummy.get_node_or_null("Body/Visual") as Sprite2D
		var rvis := real_elite.get_node_or_null("Body/Visual") as Sprite2D
		var dt: Texture2D = dvis.texture if dvis != null else null
		var rt: Texture2D = rvis.texture if rvis != null else null
		_check(dt != null and dt.resource_path.ends_with("dummy.png"),
			"木桩用的是训练假人贴图（%s）" % [dt.resource_path if dt != null else "null"])
		_check(rt != null and rt.resource_path.ends_with("enemy_sheet.png"),
			"真精英用的是敌人贴图（%s）" % [rt.resource_path if rt != null else "null"])
		_check(dt != rt, "木桩和精英的贴图确实不是同一张（不再长得一样）")
		var dd := dummy.get_node_or_null("Danger") as Area2D
		var rd := real_elite.get_node_or_null("Danger") as Area2D
		_check(dd != null and not dd.monitoring, "木桩的危险区是关的（绝对安全的沙包）")
		_check(rd != null and rd.monitoring, "真精英的危险区是开的（碰到会扣 3 血）")

		# ── 击退：木桩不动、真精英要退（阿包 2026-10-07 拍板，10-09 补上实现）──
		# 木桩被推走 = 靶子跑到够不到的地方 = 整个"试元素反应"功能废掉；
		# 而真精英要是也不退，"把敌人推下悬崖"那个环境杀特性就没了 —— 两条都要钉。
		var dpos: Vector2 = dummy.global_position
		dummy.knockback(1.0)
		for i in range(30):     # 击退动画全程 0.14s，30 帧足够跑完并回到 rest
			await physics_frame
		_check(dummy.global_position.distance_to(dpos) < 0.01,
			"木桩挨打**不会**被击退（不会被推出可达范围，位移 %.2f px）"
				% dummy.global_position.distance_to(dpos))

		var rpos: Vector2 = real_elite.global_position
		real_elite.knockback(1.0)
		for i in range(30):
			await physics_frame
		var rmove: float = real_elite.global_position.distance_to(rpos)
		_check(rmove > 1.0,
			"真精英挨打**会**退（击退是特性，位移 %.1f px —— 别把它一起改没了）" % rmove)

		# ── 击退分级：普攻小退 / 元素反应大退（阿包 10-07 的第 2 条判断，10-09 实现）──
		# 力度由敌人自己回答（get_knockback_for），玩家不查它的附着状态。
		var d_normal: float = real_elite.get_knockback_for("")
		_check(is_equal_approx(d_normal, real_elite.get_knockback_dist()),
			"普攻档 = 小退（%.0f px）" % d_normal)

		# 先用火砍一刀挂上附着，再问"换水砍会退多远" —— 那才是元素反应档
		real_elite.kill("fire")
		var d_react: float = real_elite.get_knockback_for("water")
		_check(d_react > d_normal,
			"元素反应档 > 普攻档（蒸发 %.0f px > 普攻 %.0f px）" % [d_react, d_normal])
		_check(is_equal_approx(d_react, real_elite.get_knockback_dist_reaction()),
			"反应档用的就是 KNOCKBACK_REACTION_DIST（不是随手写的数）")
		_check(is_equal_approx(real_elite.get_knockback_for("fire"), d_normal),
			"同元素不触发反应 → 仍然只给普攻档（判定没放宽）")

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

	# ── 3. 敌人压在玩家身上 = 受击（2026-10-08 改血量制，不再一击必杀）──
	var probe := _make_probe(p.global_position)
	scene.get_node("Enemies").add_child(probe)

	var hp_before: int = int(p.get("hp"))
	for i in range(30):
		await physics_frame
	var hp_after: int = int(p.get("hp"))
	_check(hp_after < hp_before,
		"敌人压在玩家身上会扣血（%d -> %d）" % [hp_before, hp_after])

	# ⭐ 回归测试：**持续**接触必须反复扣血，不能"扣一次就永久免疫"。
	#    这正是 §2.6 那条老 bug（body_entered 只在"重叠从无到有"时发一次）——
	#    改成"每物理帧轮询 + 无敌帧"之后它才真被钉住。
	#    无敌帧 0.6s（36 物理帧），所以再等 30 帧必然会扣到第二次。
	for i in range(30):
		await physics_frame
	var hp_later: int = int(p.get("hp"))
	_check(hp_later < hp_after,
		"持续接触会反复扣血（不是扣一次就免疫）—— 隐形无敌 bug 回归测试（%d -> %d）"
			% [hp_after, hp_later])

	# 清场：把探针挪走，否则后面所有断言都会被它持续扣血干扰
	probe.global_position = Vector2(-5000.0, -5000.0)
	for i in range(40):     # 顺便等无敌帧过期，免得残留一次扣血
		await physics_frame

	# ── 4. 死亡后自动回检查点 ──
	# ⚠️ 2026-10-08：不再借"被敌人碰死"来测（那是血量制之前的语义）。
	#    这里直接造成一次致命伤，专测"死亡 → 自动回检查点"这条链路。
	# 注意：检查点通常在"地面之上一点"，玩家回去后会继续下落到地面 —— 这是对的。
	# 所以断言看"是否被传回去了"，不看落点 y。
	# 阈值取 60px：足以区分"被送回检查点"和"还在原地"，又不会被落地漂移干扰。
	var pos_before_death := p.global_position
	p.take_fall_damage()     # 坠落 = 失去全部生命
	# ⚠️ 退出条件必须是"**复活完成**"，不能再用 `p.is_on_floor()`：
	#    玩家是**站在地面上**受的致命伤，死前那一帧 is_on_floor() 就是 true，
	#    而死亡会让 _physics_process 早退（不再 move_and_slide，那个值就冻在 true）——
	#    于是循环第 6 帧就 break、断言在"还没复活"时执行。
	#    实测这是 flaky：上一轮恰好过、下一轮挂（取决于死前是否恰好落地）。
	var respawned := false
	for i in range(120):
		await physics_frame
		if not p.get("_is_dead"):
			respawned = true
			break
	_check(respawned, "死亡后会自动复活（RESPAWN_DELAY 走完）")
	var cp: Vector2 = scene.get("checkpoint")
	var moved_back := absf(p.global_position.x - cp.x) < 8.0
	var was_far := absf(pos_before_death.x - cp.x) > 60.0
	_check(was_far and moved_back,
		"重开机制生效（x 从 %.0f 回到检查点 %.0f）" % [pos_before_death.x, cp.x])
	_check(int(p.get("hp")) == p.get_max_hp(),
		"复活后血量回满（%d/%d）" % [int(p.get("hp")), p.get_max_hp()])

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

	# ── 血量与受击分级（2026-10-08 阿包拍板：主角 20 血，三档伤害 / 三档反馈）──
	# 阈值一律从 Player.gd 的常量读，不写死数字（以后调手感不该让测试假失败）。
	var consts: Dictionary = p.get_script().get_script_constant_map()
	var hurt_small: int = int(consts.get("HURT_SMALL", 1))
	var hurt_medium: int = int(consts.get("HURT_MEDIUM", 3))
	var hurt_large: int = int(consts.get("HURT_LARGE", 6))

	p.respawn(Vector2(120.0, 400.0))
	await physics_frame
	_check(int(p.get("hp")) == p.get_max_hp(),
		"复活后血量回满（%d/%d）" % [int(p.get("hp")), p.get_max_hp()])

	# 小伤害：扣血，但**不抖屏**（抖动留给"真的疼"，小伤害靠闪红 + HUD 掉格）
	var hp_0: int = int(p.get("hp"))
	p.take_damage(hurt_small)
	_check(int(p.get("hp")) == hp_0 - hurt_small,
		"小伤害扣 %d 血（%d -> %d）" % [hurt_small, hp_0, int(p.get("hp"))])
	_check(float(p.get("_trauma")) <= 0.0, "小伤害不抖屏（trauma 仍为 0）")

	# 无敌帧：刚受击后立刻再打，不该再扣（否则贴着敌人 1 帧掉光血）
	var hp_1: int = int(p.get("hp"))
	p.take_damage(hurt_large)
	_check(int(p.get("hp")) == hp_1, "无敌帧内免疫伤害（挡住了一次 %d 点伤害）" % hurt_large)

	# 中伤害：扣血 + 抖屏
	p.respawn(Vector2(120.0, 400.0))
	await physics_frame
	var hp_2: int = int(p.get("hp"))
	p.take_damage(hurt_medium)
	_check(int(p.get("hp")) == hp_2 - hurt_medium, "中伤害扣 %d 血" % hurt_medium)
	_check(float(p.get("_trauma")) > 0.0, "中伤害会抖屏")
	var medium_px: float = float(p.get("_shake_max"))

	# 大伤害：抖得比中伤害**更狠**（不是换汤不换药的同档反馈）
	p.respawn(Vector2(120.0, 400.0))
	await physics_frame
	p.take_damage(hurt_large)
	_check(float(p.get("_shake_max")) > medium_px,
		"大伤害抖得比中伤害狠（%.0fpx > %.0fpx）" % [float(p.get("_shake_max")), medium_px])

	# 血量归零才死
	p.respawn(Vector2(120.0, 400.0))
	await physics_frame
	_check(not p.get("_is_dead"), "满血复活后是活的（前置条件）")
	p.take_damage(p.get_max_hp())
	_check(p.get("_is_dead"), "血量归零才判定死亡（挨了 %d 点伤害）" % p.get_max_hp())
	p.respawn(Vector2(120.0, 400.0))
	await physics_frame

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

		# ── 屏幕抖动（受击反馈）──────────────────────────────
		# ⚠️ 只断言"状态"，**不断言 camera.offset 的具体值** —— 它由噪声驱动、
		#    每帧都不同，断言具体值必然随机失败（老坑：别用随时间变化的值断言）。
		var cam: Camera2D = p.get_node_or_null("Camera2D") as Camera2D
		_check(cam != null, "玩家身上挂着 Camera2D（抖屏的载体）")
		_check(float(p.get("_trauma")) > 0.0, "受击/死亡触发了屏幕抖动（trauma > 0）")

		# 重复 die() 不该叠加（die() 自带 _is_dead 守卫）
		var trauma_after_death: float = float(p.get("_trauma"))
		p.die()
		_check(is_equal_approx(float(p.get("_trauma")), trauma_after_death),
			"重复 die() 不会重复叠加抖动（_is_dead 守卫有效）")

		# add_trauma 要 clamp 在 0~1（连续受击不能无限攒）
		p.add_trauma(5.0)
		_check(is_equal_approx(float(p.get("_trauma")), 1.0), "trauma 上限被 clamp 到 1.0")

		# 复活必须把抖动清干净 —— 否则相机歪着跟玩家跑
		p.respawn(Vector2(120.0, 400.0))
		_check(is_equal_approx(float(p.get("_trauma")), 0.0), "复活后 trauma 归零")
		_check(cam.offset == Vector2.ZERO, "复活后相机 offset 归零（不歪着复活）")

		# 抖动会自己衰减 —— 只观察"逐帧变小"，不等它归零：这期间 Main 的自动复活
		# 也会清零 trauma，那是 respawn 的正常行为，不该算成衰减的功劳
		p.add_trauma(1.0)
		var shake_decayed := false
		var t_prev: float = float(p.get("_trauma"))
		for i in range(20):
			await physics_frame
			var t_now: float = float(p.get("_trauma"))
			if t_now < t_prev:
				shake_decayed = true
				break
			t_prev = t_now
		_check(shake_decayed, "抖动会自己衰减（trauma 逐帧变小，不会永远抖）")

		# 收尾：把人放回地面，别给后面的断言留脏状态
		p.respawn(Vector2(120.0, 400.0))
		await physics_frame

	# ── 右上角元素图标（2026-10-09 阿包睡前要的：方框 + 元素图，适当扩大）──
	# ⚠️ 这类"贴图类"断言是防静默失效的：图没加载时 load() 返回 null 而且不报错，
	#    表现只是"框里空着"（§8.1 老坑）。
	var eframe := scene.get_node_or_null("HUD/ElemFrame") as Panel
	var eicon := scene.get_node_or_null("HUD/ElemIcon") as TextureRect
	_check(eframe != null, "HUD 里有元素方框（ElemFrame）")
	_check(eicon != null, "HUD 里有元素图标（ElemIcon）")
	_check(eicon != null and eicon.texture != null, "元素图标贴图已加载（不是空框）")
	if eicon != null and eicon.texture != null:
		var before_elem: String = str(p.get("element"))
		_check(eicon.texture.resource_path == "res://art/elements/%s.png" % before_elem,
			"图标贴图 == 玩家当前元素的图（%s）" % eicon.texture.resource_path)

		# 按 L 切一次：图标必须**立刻**跟着换（这是这个功能的意义所在）
		Input.action_press("switch_element")
		await physics_frame
		await physics_frame
		Input.action_release("switch_element")
		await physics_frame
		var after_elem: String = str(p.get("element"))
		_check(after_elem != before_elem,
			"按 L 切换了元素（%s → %s）" % [before_elem, after_elem])
		_check(eicon.texture != null
				and eicon.texture.resource_path == "res://art/elements/%s.png" % after_elem,
			"切元素后图标**立刻**跟着换（%s）"
				% [eicon.texture.resource_path if eicon.texture != null else "null"])

		# 再切一次切回来，别给后面的断言留脏状态
		Input.action_press("switch_element")
		await physics_frame
		await physics_frame
		Input.action_release("switch_element")
		await physics_frame
		_check(str(p.get("element")) == before_elem,
			"再切一次回到原元素（%s）—— 不给后面留脏状态" % str(p.get("element")))

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
