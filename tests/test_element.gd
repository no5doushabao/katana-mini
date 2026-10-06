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

	# ── ⭐ 木桩开关必须**真的从场景里读出来**（2026-10-07 修的 bug）──
	#
	# 根因：`is_dummy` 原来是**普通脚本变量**，而 `PackedScene.pack()` **只序列化 @export** →
	#       生成器里 `elite.set("is_dummy", true)` 一打包就被丢掉，场景文件里从来没这个属性
	#       → 运行时恒为 false，**"木桩血打空回满"从加上那天起就没生效过**（砍 4 刀照样死）。
	# 更阴的是它的**另一半**：`_ready()` 里的 `monitoring = false` 是 Area2D 的**内置属性**，
	#       反而被存进了场景 → 玩家遇到的是"不会伤害你、但会正常死"的**半吊子精英**。
	# 现在 is_dummy 加了 @export，这条断言就是防它再被静默丢弃。
	_check(elite.get("is_dummy") == true,
		"从 main.tscn 加载的精英读到了 is_dummy=true（@export 序列化没丢）")

	# setter 要**双向**同步危险区 —— 这才是"半吊子状态"的根治
	var dang := elite.get_node_or_null("Danger") as Area2D
	if dang != null:
		elite.set("is_dummy", true)
		await physics_frame
		_check(not dang.monitoring, "切到木桩：危险区自动关上（不伤害玩家）")
		elite.set("is_dummy", false)
		await physics_frame
		_check(dang.monitoring, "切回正常精英：危险区自动打开（不再残留 false）")

	# ⚠️ 地图上这个精英现在是**无限血木桩**（用户 10-07 要的，用来试元素反应）。
	#    木桩不会死、也不伤人，会把下面所有"砍 4 刀就死 / 复位满血 / 一击必杀"的断言全搞挂。
	#    所以测试要显式切回**正常精英**模式 —— 那份行为才是要被钉死的生产逻辑。
	elite.set("is_dummy", false)
	var danger_area := elite.get_node_or_null("Danger") as Area2D
	if danger_area:
		danger_area.monitoring = true
	await physics_frame

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

	# ── 元素附着（用户 10-06 定 2 秒 → 10-07 试玩后改成 3 秒；期间再次命中则计时重置）──
	# 物理帧固定 60Hz，所以"秒"可以直接换算成帧数（60 帧 = 1 秒），计时断言才可复现。
	if not elite.has_method("has_aura"):
		_fails.append("★ 精英没有 has_aura —— 元素附着没实现？")
	else:
		var aura_dur: float = elite.call("get_aura_duration")
		var blink_at: float = elite.call("get_aura_blink_at")

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
		_check(left_hit > aura_dur - 0.2 and left_hit <= aura_dur,
			"刚命中时剩余 ≈%.1f 秒（实际 %.2f）" % [aura_dur, left_hit])

		# 1) 过 1 秒：附着仍在，剩余约 dur-1
		for i in range(60):
			await physics_frame
		_check(elite.has_aura(), "过 1 秒后附着仍在")
		var left_mid: float = elite.get_aura_left()
		_check(left_mid > aura_dur - 1.3 and left_mid < aura_dur - 0.7,
			"过 1 秒后剩余 ≈%.1f 秒（实际 %.2f）" % [aura_dur - 1.0, left_mid])

		# 2) 窗口内**再次命中** -> 计时重置回满（而不是累加、也不是不刷新）
		elite.kill("fire")
		await physics_frame
		var left_reset: float = elite.get_aura_left()
		_check(left_reset > aura_dur - 0.1,
			"窗口内再次命中 -> 计时重置回 %.1f 秒（实际 %.2f）" % [aura_dur, left_reset])

		# 3) 从重置点起一直不打 -> 附着到时间自动消失
		for i in range(int(aura_dur * 60) + 20):
			await physics_frame
		_check(not elite.has_aura(), "窗口内不再命中 -> 附着消失（剩余 %.2f）" % elite.get_aura_left())
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

			# ── 闪烁规则（用户 10-07）：前段常亮、后段才闪 ──
			# 把"剩余时间"编码进"闪不闪"里：不闪 = 还久，闪 = 快没了、该出手了。
			# 先采**前段**（剩余时间 > AURA_BLINK_AT）：应当恒亮，不能有明暗波动。
			var early_min := 1.1
			for i in range(30):                      # 0.5 秒，仍在 3 秒的前段里
				await physics_frame
				early_min = minf(early_min, icon.modulate.a)
			_check(early_min > 0.9,
				"前段（剩余 > %.1f 秒）图标常亮不闪（最低 alpha=%.2f）" % [blink_at, early_min])
			_check(elite.get_aura_left() > blink_at,
				"采样结束时确实还在前段（剩余 %.2f > %.2f）" % [elite.get_aura_left(), blink_at])

			# 再采**后段**：等到剩余时间掉进警告期再采样，应当有明显明暗变化。
			var guard := 0
			while elite.get_aura_left() > blink_at - 0.15 and guard < 400:
				await physics_frame
				guard += 1
			var late_min := 1.1
			var late_max := -0.1
			for i in range(40):
				await physics_frame
				late_min = minf(late_min, icon.modulate.a)
				late_max = maxf(late_max, icon.modulate.a)
			_check(late_max - late_min > 0.25,
				"后段（剩余 <= %.1f 秒）图标开始闪烁（alpha %.2f ~ %.2f）" % [blink_at, late_min, late_max])

			# 受击重置后应当**回到常亮**（警告解除）—— 这是"连续砍就一直不闪"的根据
			elite.kill("fire")
			await physics_frame
			var reset_min := 1.1
			for i in range(30):
				await physics_frame
				reset_min = minf(reset_min, icon.modulate.a)
			_check(reset_min > 0.9,
				"重置附着后图标回到常亮（最低 alpha=%.2f）—— 连续同元素砍就一直不闪" % reset_min)

			# 图标挂根节点：不跟着受击缩放一起抖
			_check(icon.get_parent() == elite, "图标挂在精英根节点上（不被受击缩放带动）")

			# 附着结束后图标收起
			elite.reset_enemy()
			await physics_frame
			_check(not icon.visible, "复位后头顶图标隐藏")

	# ── 元素切换（用户 2026-10-06 晚：一个按钮循环切换属性）──
	if not p.has_method("get_element_label"):
		_fails.append("★ 玩家没有 get_element_label —— 元素切换没实现？")
	else:
		p.global_position = Vector2(200.0, 400.0)      # 挪到安全处，切换不需要靠近敌人
		p.velocity = Vector2.ZERO
		for i in range(10):
			await physics_frame

		_check(p.get("element") == "fire", "开局是火（实际 %s）" % p.get("element"))

		Input.action_press("switch_element")
		await physics_frame
		await physics_frame
		Input.action_release("switch_element")
		_check(p.get("element") == "water", "按 L 后变成水（实际 %s）" % p.get("element"))
		_check(p.get("element_index") == 1, "索引跟到 1（实际 %s）" % str(p.get("element_index")))

		# 月牙颜色要跟着元素走（这是玩家"看出来是什么属性"的主渠道）
		Input.action_press("attack")
		await physics_frame
		await physics_frame
		var water_arc: Color = p.call("get_arc_color")
		Input.action_release("attack")
		_check(water_arc.b > water_arc.r, "水元素下月牙偏蓝（r=%.2f b=%.2f）" % [water_arc.r, water_arc.b])
		for i in range(30):
			await physics_frame

		# 再按一次要回到火 —— 是**循环**，不是卡在水
		Input.action_press("switch_element")
		await physics_frame
		await physics_frame
		Input.action_release("switch_element")
		_check(p.get("element") == "fire", "再按一次回到火（实际 %s）" % p.get("element"))
		_check(p.get("element_index") == 0, "索引回到 0（实际 %s）" % str(p.get("element_index")))

	# ── 蒸发反应（火附着 + 水打）──
	if not elite.has_method("resolve_reaction"):
		_fails.append("★ 精英没有 resolve_reaction —— 元素反应没实现？")
	else:
		# 1) 判定表本身
		elite.reset_enemy()
		await physics_frame
		elite.kill("fire")
		await physics_frame
		_check(elite.get_aura() == "fire", "前置：身上挂着火")
		_check(elite.resolve_reaction("water") == "vaporize", "火附着 + 水 → 蒸发")
		_check(elite.resolve_reaction("fire") == "", "火附着 + 火 → 不反应（同元素）")
		_check(elite.resolve_reaction("") == "", "空元素 → 不反应")
		_check(elite.resolve_reaction("thunder") == "", "未登记的组合 → 不反应（不会乱触发）")

		# 2) 实际伤害：水打火 = 扣 2 血（1 + 蒸发加成）
		var reacted_log: Array[String] = []
		elite.reacted.connect(func(kind: String, _dmg: int) -> void: reacted_log.append(kind))
		var hp_before: int = elite.get_hp()
		elite.kill("water")
		await physics_frame
		_check(elite.get_hp() == hp_before - 2,
			"蒸发一刀扣 2 血（%d -> %d）" % [hp_before, elite.get_hp()])
		_check(reacted_log.size() == 1 and reacted_log[0] == "vaporize",
			"reacted 信号发出了 vaporize（实际 %s）" % str(reacted_log))

		# 3) 反应会消耗附着 —— 想再蒸发就得重新挂火
		_check(elite.get_aura() == "", "蒸发消耗掉了火附着（想再蒸发要重新挂火）")

		# 4) 同元素攻击：只扣 1 血，但**刷新**附着计时
		elite.reset_enemy()
		await physics_frame
		elite.kill("fire")
		await physics_frame
		for i in range(60):
			await physics_frame
		var mid_left: float = elite.get_aura_left()
		var mid_hp: int = elite.get_hp()
		elite.kill("fire")
		await physics_frame
		_check(elite.get_hp() == mid_hp - 1, "同元素攻击只扣 1 血（%d -> %d）" % [mid_hp, elite.get_hp()])
		_check(elite.get_aura_left() > mid_left,
			"同元素攻击刷新了附着计时（%.2f -> %.2f）" % [mid_left, elite.get_aura_left()])

		# 5) 一路反应打到死：血量要 clamp 到 0，不能出现负数
		elite.reset_enemy()
		await physics_frame
		elite.kill("fire")     # 4 -> 3（挂火）
		elite.kill("water")    # 3 -> 1（蒸发扣 2，消耗附着）
		elite.kill("fire")     # 1 -> 0（死）
		await physics_frame
		_check(elite.get_hp() == 0, "连续反应后血量 clamp 到 0，不是负数（实际 %d）" % elite.get_hp())
		_check(elite.is_dead(), "血尽即死")
		elite.reset_enemy()
		await physics_frame

		# 6) 反应视觉 + 锁定窗口（用户 10-07 的方案 B：两个图标相撞，期间不能挂新元素）
		elite.reset_enemy()
		await physics_frame
		var recon: Sprite2D = elite.call("get_reaction_icon")
		var aicon: Sprite2D = elite.call("get_aura_icon")
		if recon == null or aicon == null:
			_fails.append("缺少 AuraIcon / ReactionIcon 节点（生成器没建？）")
		else:
			var lock_time: float = elite.call("get_reaction_lock")
			# ⚠️ 临时加血：蒸发一刀扣 2，4 血经不起"挂火 → 蒸发 → 锁定期再砍一刀"这套组合，
			#    不补血的话会在验证锁定期之前就被打死，后续断言全部失效。
			elite.set("hp", 12)

			elite.kill("fire")
			await physics_frame
			_check(not recon.visible, "平时反应图标是隐藏的")

			# 蒸发：两个图标应该**同时出现**（方案 B 的起点就是方案 A）
			elite.kill("water")
			await physics_frame
			_check(aicon.visible, "反应时旧元素的图标在场")
			_check(recon.visible, "反应时新元素的图标也进场（两个图标同框）")
			_check(recon.texture != null, "反应图标贴图已加载")

			# 锁定窗口
			var left_now: float = elite.call("get_reaction_left")
			_check(left_now > 0.0, "反应后进入锁定窗口（剩余 %.2f 秒）" % left_now)
			_check(left_now <= lock_time + 0.05,
				"锁定时长不超过 %.2f 秒（实际 %.2f）" % [lock_time, left_now])

			# 锁定期间：**挂不上新附着**，但**伤害照常**
			var hp_locked: int = elite.get_hp()
			elite.kill("fire")
			await physics_frame
			_check(not elite.has_aura(), "锁定窗口内挂不上新附着（用户要的）")
			_check(elite.get_hp() < hp_locked,
				"但伤害照常结算（%d -> %d）—— 只锁附着，不锁伤害" % [hp_locked, elite.get_hp()])

			# 等锁定结束
			for i in range(int(lock_time * 60) + 8):
				await physics_frame
			_check(elite.call("get_reaction_left") <= 0.0, "锁定窗口已结束")

			# 动画比锁定长得多（撞 0.15 + 爆 0.10 + 上升 0.55 = 0.80 > 锁 0.30）——
			# 这是"动画时长与锁定**故意解耦**"的直接证据。
			#
			# ⚠️ 2026-10-07 修：原来这里断言的是 `recon.visible`（"锁定结束时图标还在"），
			#    但那条断言**在 headless 下不可靠**：Tween 按**渲染帧的真实时间**推进，
			#    而锁定的 `_reaction_left` 按**物理 delta** 递减 —— 两者不同步
			#    （物理帧可能跑得比渲染帧慢很多），于是"锁定刚结束"时动画可能早就播完了，
			#    断言随机失败。**改成直接比较两个常量**：这才是这条设计的本体，且与帧率无关。
			var anim_time: float = elite.call("get_reaction_anim_time")
			_check(anim_time > lock_time,
				"动画时长(%.2f 秒) > 锁定长度(%.2f 秒) —— 两者故意解耦" % [anim_time, lock_time])

			# ── 动画是否真的走了"撞 → 爆 → 上升淡化"三段 ──
			#
			# ⚠️ 这里**不能靠采样位置或数物理帧**来判断动画进度：
			#    Tween 按**渲染帧的真实时间**推进，而测试只能 await physics_frame；
			#    headless 下一次 await 之间可能跑过好几个渲染帧
			#    （实测：等 26 个物理帧后，0.8 秒的动画已经播完 84%，
			#      采到的 y/alpha 是**复位后**的值，断言全错）。
			#    所以改成读动画自己上报的阶段日志。
			for i in range(90):                    # 宽松等待，确保动画播完
				await physics_frame
			var phases: Array = elite.call("get_reaction_phases")
			_check(phases.has("hit"), "动画经历过「相撞」段（实际 %s）" % str(phases))
			_check(phases.has("burst"), "动画经历过「爆亮」段（实际 %s）" % str(phases))
			_check(phases.has("rise"), "动画经历过「上升淡化」段（实际 %s）" % str(phases))
			_check(phases.size() >= 3 and phases[0] == "hit" and phases[-1] == "rise",
				"阶段顺序是 撞 → 爆 → 上升（实际 %s）" % str(phases))
			_check(not recon.visible, "动画播完后反应图标隐藏")
			_check(not aicon.visible, "动画播完后附着图标也隐藏（附着已被反应消耗）")

			# 锁定结束后能重新挂上
			elite.kill("fire")
			await physics_frame
			_check(elite.has_aura() and elite.get_aura() == "fire", "锁定结束后能重新挂上火")

		elite.reset_enemy()
		await physics_frame

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

	# ── 木桩模式（用户 10-07：无限血木桩，用来反复试元素反应）──
	# 地图上那个精英本身就是木桩，前面为了钉生产逻辑临时关掉了，这里再打开。
	elite.set("is_dummy", false)
	elite.reset_enemy()
	await physics_frame
	elite.set("is_dummy", true)
	elite.reset_enemy()
	await physics_frame
	_check(elite.get("is_dummy") == true, "木桩模式已打开")

	# 1) 血打空**不死**，而是回满
	var died_count2 := [0]
	elite.died.connect(func() -> void: died_count2[0] += 1)
	for i in range(6):                       # 6 刀足够把 4 血打空一轮（普通一刀 1 血）
		elite.kill("fire")
		await physics_frame
	_check(not elite.is_dead(), "木桩血打空也不死")
	_check(died_count2[0] == 0, "木桩不发 died 信号（否则计分会乱）")
	_check(elite.get_hp() > 0,
		"木桩血量已回满（实际 %d/%d）" % [elite.get_hp(), elite.call("get_max_hp")])

	# 2) 木桩不伤害玩家
	if danger_area:
		_check(not danger_area.monitoring, "木桩的危险区是关掉的（不伤害玩家）")

	# 3) 木桩照样能挂附着、触发反应 —— 这才是它存在的意义
	var reacted2: Array[String] = []
	elite.reacted.connect(func(kind: String, _d: int) -> void: reacted2.append(kind))
	elite.reset_enemy()
	await physics_frame
	elite.kill("fire")
	await physics_frame
	_check(elite.has_aura() and elite.get_aura() == "fire", "木桩照样能挂元素附着")
	elite.kill("water")
	await physics_frame
	_check(reacted2.has("vaporize"), "木桩上照样能触发蒸发（实际 %s）" % str(reacted2))

	# ── ⭐ 图标尺寸的连带关系（2026-10-07：图标 24x24 -> 32x32 时补的）──
	#
	# 换图标尺寸**看起来只是换个素材**，其实牵着两个常量：
	#   (a) ICON_Y —— 图标底部到中心的距离从 12 变 16，不动它图标会**压进精英头顶**
	#   (b) REACTION_SPREAD —— 两个图标一起变宽，不动它反应动画**开场就重叠**
	# 两者都不报错、不崩，只会"看着有点怪"，所以必须用测试钉住。
	# ⚠️ 断言一律从**贴图尺寸和精英自身缩放**推导，不写死数字（素材和地图都会变）。
	var icon2: Sprite2D = elite.call("get_aura_icon")
	if icon2 != null and icon2.texture != null:
		var isz: Vector2 = icon2.texture.get_size()
		var consts: Dictionary = elite.get_script().get_script_constant_map()
		var want_y: float = float(consts.get("ICON_Y", 0.0))
		var spread: float = float(consts.get("REACTION_SPREAD", 0.0))

		_check(is_equal_approx(isz.x, isz.y), "元素图标是正方形（%d x %d）" % [isz.x, isz.y])

		var evis := elite.get_node_or_null("Body/Visual") as Sprite2D
		# ⚠️ 用 `_base_scale`（静止时的缩放），**不要**读 `evis.scale` ——
		#    后者会被"受击放大回弹"动画改（HIT_PUNCH_SCALE），
		#    于是这条断言会随"采样时它是否正在挨打"随机失败（2026-10-07 实测踩到）。
		var base_scale: Vector2 = elite.get("_base_scale")
		var body_top := -INF
		if evis != null and evis.texture != null:
			body_top = -float(evis.texture.get_height()) * absf(base_scale.y) * 0.5
		_check(want_y + isz.y * 0.5 <= body_top,
			"图标不压进精英头顶（图标底 %.0f ≤ 主体顶 %.0f）" % [want_y + isz.y * 0.5, body_top])

		_check(spread * 2.0 >= isz.x,
			"相撞前两图标不重叠（中心距 %.0f ≥ 图标宽 %.0f）" % [spread * 2.0, isz.x])

		# 场景里摆的位置必须等于脚本里的 ICON_Y —— 注释写了"必须一致"，但注释不会报警
		_check(is_equal_approx(icon2.position.y, want_y),
			"场景里图标位置 == ICON_Y 常量（%.0f vs %.0f），生成器和脚本别各写一个数"
			% [icon2.position.y, want_y])

	# ── 七元素图标齐备且规格统一（用户 2026-10-07：七元素图标统一升到 32x32）──
	# 这份名字列表本身就是**规格**（哪七种元素）；尺寸从实际 PNG 读，不写死常量。
	var icon_names := ["fire", "water", "wind", "thunder", "grass", "ice", "rock"]
	var missing: Array[String] = []
	var wrong_size: Array[String] = []
	for nm in icon_names:
		var pth := "res://art/elements/%s.png" % nm
		if not ResourceLoader.exists(pth):
			missing.append(nm)
			continue
		var tex := load(pth) as Texture2D
		if tex == null:
			# load() 对新 PNG 返回 null 且**不报错** —— 多半是没跑 godot --import
			missing.append(nm + "(load 返回 null，多半是没重新 import)")
		elif tex.get_width() != 32 or tex.get_height() != 32:
			wrong_size.append("%s=%dx%d" % [nm, tex.get_width(), tex.get_height()])
	_check(missing.is_empty(), "七元素图标文件齐备（缺 %s）" % str(missing))
	_check(wrong_size.is_empty(), "七元素图标都是 32x32（异常 %s）" % str(wrong_size))

	# ── 死亡后头顶图标必须一起收掉（用户 2026-10-07 报的 bug）──
	#
	# 现象："怪物死亡以后，头上的元素符号仍然存在。"
	# 根因两层：① `_hide_on_death()` 只隐藏了 visual（Body/Visual），而图标挂在**根节点**上
	#            （故意的，避免受击缩放带着它抖）→ 敌人没了、图标还在闪；
	#          ② 附着状态也没清，`_physics_process` 继续给那 3 秒计时 → 会闪到自然耗尽。
	# 修法：死亡时清附着状态 + 让图标**跟敌人同步淡出**（0.26 秒，见 DEATH_* 常量）。
	#
	# ⚠️ headless 下"物理帧 ≠ 渲染帧"，Tween 按**真实时间**推进 ——
	#    所以这里不数帧猜进度，只用足够长的等待，并检查"淡出过 + 最终隐藏"。
	if icon2 != null:
		elite.set("is_dummy", false)          # 木桩不会死，得先切回正常精英
		elite.reset_enemy()
		await physics_frame
		elite.kill("fire")
		await physics_frame
		_check(icon2.visible, "挂上附着后图标可见（前置条件）")

		for i in range(4):                    # MAX_HP=4，普通一刀 1 血
			elite.kill("fire")
			await physics_frame
		_check(elite.is_dead(), "精英已死亡（前置条件）")

		# 状态层应当**同步**清空，不用等动画
		_check(not elite.has_aura(),
			"死亡后附着状态立刻清空（否则还会给它计时 3 秒）")

		# 视觉层：给足时间，同时采样"确实淡出过"（而不是被瞬间掐掉）
		var saw_fading := false
		var waited := 0.0
		while waited < 0.6:
			await physics_frame
			waited += 1.0 / 60.0
			if icon2.visible and icon2.modulate.a < 0.9:
				saw_fading = true
		_check(saw_fading, "死亡时头顶图标是**淡出**的（不是瞬间硬切）")
		_check(not icon2.visible, "淡出播完后头顶图标隐藏（不再残留）")

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
