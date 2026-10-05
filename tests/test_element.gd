extends SceneTree
## 元素附魔 + 精英敌人验证
## 运行：Godot --headless --path <项目> --script tests/test_element.gd
##
## 钉死的行为（用户 2026-10-06 拍板：先做火元素 + 精英 4 滴血）：
##   1. 精英敌人初始 4 滴血，砍一刀不会死
##   2. 砍满 4 刀才死，且 died 信号**恰好发一次**（Main.gd 靠它计分）
##   3. 精英死后**留在树上、不退组、不 queue_free**（检查点复位链路依赖这点）
##   4. 复位后**满血**
##   5. 玩家攻击时角色染成火色，攻击窗口结束后恢复
##   6. 杂兵依旧一击必杀（元素参数不该破坏原来的爽感）
##
## 沿用 test_core.gd 的两条经验：
##   • 注入输入后必须等 2 个物理帧，just_pressed 才为 true
##   • 动态造节点要先把子树搭好再 add_child

var _fails: Array[String] = []
var _passes: Array[String] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var scene: Node = (load("res://main.tscn") as PackedScene).instantiate()
	root.add_child(scene)
	await physics_frame

	var p: CharacterBody2D = scene.get_node("Player") as CharacterBody2D

	# ── 找精英：用组，别写死节点名（地图是生成的）──
	var elite: Node2D = null
	for n in get_nodes_in_group("elite"):
		elite = n as Node2D
		break
	if elite == null:
		_fails.append("★ 地图里找不到精英敌人（elite 组为空）—— 生成器没建出来？")
		_finish()
		return
	_check(true, "地图里有精英敌人（%s）" % elite.name)
	_check(elite.get_hp() == 4, "精英初始 4 滴血（实际 %d）" % elite.get_hp())
	_check(not elite.is_dead(), "精英初始是活的")

	# ── 玩家落到地面 ──
	for i in range(120):
		await physics_frame
		if i > 10 and p.is_on_floor():
			break
	_check(p.is_on_floor(), "玩家落到地面")

	# ── 挪到精英左侧 55px ──
	# 55 沿用 test_core 的安全命中窗口：够得着，又不会站进它的危险区被撞死。
	p.global_position = Vector2(elite.global_position.x - 55.0, elite.global_position.y)
	p.velocity = Vector2.ZERO
	for i in range(12):
		await physics_frame

	var died_count := [0]
	elite.died.connect(func() -> void: died_count[0] += 1)
	var dmg_log: Array[int] = []
	elite.damaged.connect(func(remaining: int) -> void: dmg_log.append(remaining))

	# ── 前 3 刀：都该活着 ──
	for n in range(3):
		Input.action_press("attack")
		await physics_frame
		await physics_frame
		Input.action_release("attack")
		for i in range(20):
			await physics_frame
		_check(elite.get_hp() == 3 - n, "第 %d 刀后剩 %d 血（实际 %d）" % [n + 1, 3 - n, elite.get_hp()])
		_check(not elite.is_dead(), "砍 %d 刀后精英还活着" % (n + 1))
		_check(died_count[0] == 0, "砍 %d 刀时不该发 died 信号" % (n + 1))

	# ── 第 4 刀：血尽 ──
	var kills_before: int = scene.get("kills")
	Input.action_press("attack")
	await physics_frame
	await physics_frame
	Input.action_release("attack")
	for i in range(30):
		await physics_frame

	_check(elite.get_hp() == 0, "第 4 刀后血量归零（实际 %d）" % elite.get_hp())
	_check(elite.is_dead(), "第 4 刀后精英死亡")
	_check(died_count[0] == 1, "died 信号恰好发一次（实际 %d）" % died_count[0])
	_check(dmg_log.size() == 4, "damaged 信号发 4 次（实际 %d）" % dmg_log.size())
	_check(scene.get("kills") == kills_before + 1,
		"击杀数只 +1（%d -> %d）" % [kills_before, scene.get("kills")])

	# ── 死后仍在树上（复位链路的前提）──
	_check(is_instance_valid(elite) and elite.is_in_group("enemy"),
		"死后仍在树上且保留 enemy 组（检查点复位要靠它）")

	# ── 复位：满血 ──
	if elite.has_method("reset_enemy"):
		elite.reset_enemy()
		await physics_frame
		_check(elite.get_hp() == 4, "复位后满血（实际 %d）" % elite.get_hp())
		_check(not elite.is_dead(), "复位后不再是死亡状态")
		var vis := elite.get_node_or_null("Body/Visual") as Sprite2D
		if vis:
			_check(vis.visible and vis.modulate.a > 0.99,
				"复位后视觉恢复（visible=%s alpha=%.2f）" % [str(vis.visible), vis.modulate.a])
	else:
		_fails.append("精英缺少 reset_enemy（检查点复位会失败）")

	# ── 火元素的视觉：**攻击范围（月牙）**变红，角色本体不变色 ──
	# 用户 2026-10-06 明确纠正过：要红的是攻击范围，不是角色（"用小月牙的形状来模拟攻击范围"）。
	# 先挪远，避免取色期间被精英撞死
	p.global_position = Vector2(elite.global_position.x - 200.0, elite.global_position.y)
	p.velocity = Vector2.ZERO
	for i in range(8):
		await physics_frame

	# 1) 角色本体**不该**变色
	var sprite := scene.get_node_or_null("Player/Visual") as Sprite2D
	if sprite == null:
		_fails.append("找不到 Player/Visual")
	else:
		var body_tint := sprite.modulate
		_check(body_tint.r > 0.95 and body_tint.g > 0.95 and body_tint.b > 0.95,
			"角色本体不染色（%.2f, %.2f, %.2f）—— 元素表现在攻击范围上" % [body_tint.r, body_tint.g, body_tint.b])

	# 2) 非攻击时月牙几乎不可见
	var idle_arc: Color = p.call("get_arc_color")
	_check(idle_arc.a < 0.15, "非攻击时月牙几乎不可见（alpha=%.2f）" % idle_arc.a)

	# 3) 攻击时月牙变火色
	Input.action_press("attack")
	await physics_frame
	await physics_frame
	var fire_arc: Color = p.call("get_arc_color")
	var arc_poly: PackedVector2Array = p.call("_build_arc_polygon")
	Input.action_release("attack")
	_check(fire_arc.r > 0.95 and fire_arc.g < 0.6 and fire_arc.b < 0.4 and fire_arc.a > 0.5,
		"攻击时月牙是火色（%.2f, %.2f, %.2f, a=%.2f）" % [fire_arc.r, fire_arc.g, fire_arc.b, fire_arc.a])

	# 4) 月牙形状：顶点数 = 2*(段数+1)，两头收尖（月牙而不是扇环）
	_check(arc_poly.size() == 34, "月牙多边形顶点数 = 2*(16+1)（实际 %d）" % arc_poly.size())
	var max_r := 0.0
	var min_r := 99999.0
	for v in arc_poly:
		max_r = maxf(max_r, v.length())
		min_r = minf(min_r, v.length())
	_check(absf(max_r - 62.0) < 3.0, "月牙外半径 ≈ 62，覆盖判定框外缘 59（实际 %.1f）" % max_r)
	_check(min_r > 18.0, "月牙内缘不糊在角色身上（最小半径 %.1f > 角色半宽 18）" % min_r)

	# 5) 月牙朝**面朝方向**展开，而不是糊在脸上或甩在背后
	var outer_mid: Vector2 = arc_poly[8]          # 外弧中点（16 段 -> 索引 8）
	var facing_now: int = p.get("facing")
	_check(outer_mid.normalized().x * float(facing_now) > 0.5,
		"月牙朝前方展开（外弧中点 x=%.1f, facing=%d）" % [outer_mid.x, facing_now])

	# 6) 攻击窗口结束后收回
	for i in range(30):
		await physics_frame
	var back_arc: Color = p.call("get_arc_color")
	_check(back_arc.a < 0.15, "攻击窗口结束后月牙收回（alpha=%.2f）" % back_arc.a)

	# ── 元素附着（用户 2026-10-06 的规则：持续 2 秒，2 秒内再次命中则计时重置）──
	# 物理帧固定 60Hz，所以"秒"可以直接换算成帧数（60 帧 = 1 秒），计时断言才可复现。
	if not elite.has_method("has_aura"):
		_fails.append("★ 精英没有 has_aura —— 元素附着没实现？")
	else:
		# 0) 端到端：**玩家的攻击**应该把火元素传到精英身上（而不只是直接调 kill）
		elite.reset_enemy()
		p.global_position = Vector2(elite.global_position.x - 55.0, elite.global_position.y)
		p.velocity = Vector2.ZERO
		for i in range(12):
			await physics_frame
		Input.action_press("attack")
		await physics_frame
		await physics_frame
		Input.action_release("attack")
		for i in range(12):
			await physics_frame
		_check(elite.get_aura() == "fire",
			"玩家攻击把火元素传到了精英（实际 '%s'）" % elite.get_aura())
		var left_hit: float = elite.get_aura_left()
		_check(left_hit > 1.8 and left_hit <= 2.0, "刚命中时剩余 ≈2 秒（实际 %.2f）" % left_hit)

		# 1) 过 1 秒：附着仍在，剩余约 1 秒
		for i in range(60):
			await physics_frame
		_check(elite.has_aura(), "过 1 秒后附着仍在")
		var left_mid: float = elite.get_aura_left()
		_check(left_mid > 0.7 and left_mid < 1.3, "过 1 秒后剩余 ≈1 秒（实际 %.2f）" % left_mid)

		# 2) 2 秒内**再次命中** -> 计时重置回 2 秒（而不是累加、也不是不刷新）
		elite.kill("fire")
		await physics_frame
		var left_reset: float = elite.get_aura_left()
		_check(left_reset > 1.9, "2 秒内再次命中 -> 计时重置回 2 秒（实际 %.2f）" % left_reset)

		# 3) 从重置点起再过 2.2 秒都没打 -> 附着到时间自动消失
		for i in range(132):
			await physics_frame
		_check(not elite.has_aura(), "2 秒内不再命中 -> 附着消失（剩余 %.2f）" % elite.get_aura_left())
		_check(elite.get_aura() == "", "附着元素已清空")

		# 4) 不带元素的攻击不该产生附着（否则以后做反应会出现"凭空蒸发"）
		elite.reset_enemy()
		await physics_frame
		elite.kill("")
		await physics_frame
		_check(not elite.has_aura(), "无元素攻击（kill(\"\")）不产生附着")

		# 5) 复位要清空附着：否则死一次复活回来身上还带着火
		elite.kill("fire")
		await physics_frame
		_check(elite.has_aura(), "再次附着成功（前置条件）")
		elite.reset_enemy()
		await physics_frame
		_check(not elite.has_aura(), "复位后附着被清空")

		# 6) 附着必须**看得见**：底色调向火色。
		#    没有这条断言的话，"挂上了但玩家看不出来"这种 bug 是测不出来的 ——
		#    而对一个状态类机制来说，"玩家知不知道它挂上了"和机制本身一样重要。
		elite.kill("fire")
		await physics_frame
		var tinted: Color = elite.call("_base_modulate")
		_check(tinted.r > tinted.g and tinted.g > 0.1,
			"附着期间底色偏火色（%.2f, %.2f, %.2f）" % [tinted.r, tinted.g, tinted.b])
		elite.reset_enemy()
		await physics_frame
		var clean: Color = elite.call("_base_modulate")
		_check(absf(clean.r - 1.0) < 0.01 and absf(clean.g - 1.0) < 0.01 and absf(clean.b - 1.0) < 0.01,
			"无附着时底色恢复纯白（%.2f, %.2f, %.2f）" % [clean.r, clean.g, clean.b])

		# 7) 头顶元素图标（用户 2026-10-06：被附着的角色头顶闪烁元素图标）
		var icon: Sprite2D = elite.call("get_aura_icon")
		if icon == null:
			_fails.append("精英没有 AuraIcon 节点（生成器没建出来？）")
		else:
			_check(not icon.visible, "无附着时头顶图标隐藏")

			elite.kill("fire")
			await physics_frame
			_check(icon.visible, "附着后头顶图标显示")
			_check(icon.texture != null,
				"图标贴图已加载（不是 null —— 新 PNG 没 import 时这里会踩坑）")
			var tex_path := ""
			if icon.texture != null:
				tex_path = icon.texture.resource_path
			_check(tex_path.ends_with("fire.png"), "图标用的是 fire.png（实际 %s）" % tex_path)

			# 闪烁：采一段时间的 alpha，既不能恒 1 也不能恒 0
			var amin := 1.1
			var amax := -0.1
			for i in range(40):
				await physics_frame
				amin = minf(amin, icon.modulate.a)
				amax = maxf(amax, icon.modulate.a)
			_check(amax - amin > 0.25,
				"图标在闪烁（alpha 在 %.2f ~ %.2f 之间变化）" % [amin, amax])

			# 图标挂根节点：不跟着受击缩放一起抖
			_check(icon.get_parent() == elite, "图标挂在精英根节点上（不被受击缩放带动）")

			# 附着结束后图标收起
			elite.reset_enemy()
			await physics_frame
			_check(not icon.visible, "复位后头顶图标隐藏")

	# ── 杂兵依旧一击必杀 ──
	var normal: Node2D = null
	for n in get_nodes_in_group("enemy"):
		if n.has_method("get_hp"):
			continue                  # 这是精英（有血量）
		if n is CharacterBody2D:
			continue                  # 巡逻兵是另一套
		normal = n as Node2D
		break
	if normal == null:
		_fails.append("地图里找不到普通杂兵")
	else:
		normal.kill("fire")
		await physics_frame
		_check(normal.is_dead(), "杂兵依旧一击必杀（带元素参数也不该改变它）")

	_finish()


func _check(cond: bool, label: String) -> void:
	if cond:
		_passes.append(label)
	else:
		_fails.append(label)


func _finish() -> void:
	for s in _passes:
		push_error("  ✓ " + s)
	for s in _fails:
		push_error("  ✗ " + s)
	if _fails.is_empty():
		push_error("ELEMENT_OK 通过 %d 项" % _passes.size())
		quit(0)
	else:
		push_error("ELEMENT_FAIL 失败 %d 项 / 通过 %d 项" % [_fails.size(), _passes.size()])
		quit(1)
