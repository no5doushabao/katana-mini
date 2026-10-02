extends SceneTree
## 验证检查点系统 + 敌人复位（本轮新增的两个前置项）
##
## 这两件事之前都不存在，是"地图能玩"的地基：
##   ① checkpoint 只在 _ready() 里赋值一次 → 死了永远回出生点
##   ② 敌人死后被 queue_free() 删除 → 检查点复位找不到它


func _initialize() -> void:
	_run.call_deferred()


func _adv(frames: int) -> void:
	for i in range(frames):
		await physics_frame


func _run() -> void:
	var packed: PackedScene = load("res://main.tscn")
	var scene: Node = packed.instantiate()
	root.add_child(scene)
	await _adv(60)

	var fails: Array[String] = []
	var oks: Array[String] = []

	var cp0: Vector2 = scene.get("checkpoint")
	oks.append("初始检查点 = %s" % str(cp0.round()))

	# ── ① set_checkpoint 能更新复活点 ──
	scene.call("set_checkpoint", Vector2(1200.0, 400.0))
	var cp1: Vector2 = scene.get("checkpoint")
	if absf(cp1.x - 1200.0) < 0.1:
		oks.append("set_checkpoint 生效（%s）" % str(cp1.round()))
	else:
		fails.append("★ set_checkpoint 没生效：仍是 %s" % str(cp1.round()))

	# 不能倒退（走回头路不该把检查点弄回去）
	scene.call("set_checkpoint", Vector2(300.0, 400.0))
	var cp2: Vector2 = scene.get("checkpoint")
	if absf(cp2.x - 1200.0) < 0.1:
		oks.append("检查点不会倒退（传 300 仍保持 1200）")
	else:
		fails.append("★ 检查点被倒退到了 %s" % str(cp2.round()))

	# ── ② 敌人死亡后仍在场景里（能被复位找回）──
	var enemies := get_nodes_in_group("enemy")
	oks.append("场上敌人节点数 = %d" % enemies.size())

	# 找一个敌人杀掉
	var target: Node = null
	for e in enemies:
		if e.has_method("kill"):
			target = e
			break
	if target == null:
		fails.append("找不到可击杀的敌人")
	else:
		var before_pos: Vector2 = (target as Node2D).global_position
		target.call("kill")
		await _adv(40)

		if not is_instance_valid(target):
			fails.append("★ 敌人死后被删除了（queue_free）—— 复位逻辑将找不到它")
		else:
			oks.append("敌人死后节点仍在（没被 queue_free）")
			if target.has_method("is_dead") and target.call("is_dead"):
				oks.append("is_dead() 正确报告为已死")
			else:
				fails.append("★ is_dead() 没报告已死")

			# 还在 "enemy" 组里吗？复位逻辑靠这个找它
			if target.is_in_group("enemy"):
				oks.append("死后仍留在 enemy 组（复位能找到）")
			else:
				fails.append("★ 死后退出了 enemy 组 —— 复位会找不到它")

			# ── ③ reset_enemy 能复活它 ──
			if target.has_method("reset_enemy"):
				# 先把它挪开，看复位能不能拉回原位
				(target as Node2D).global_position = before_pos + Vector2(500, 0)
				target.call("reset_enemy")
				await _adv(10)
				var now_dead: bool = target.call("is_dead") if target.has_method("is_dead") else true
				var now_pos: Vector2 = (target as Node2D).global_position
				if not now_dead:
					oks.append("reset_enemy 复活成功")
				else:
					fails.append("★ reset_enemy 没能复活（is_dead 仍为 true）")
				if now_pos.distance_to(before_pos) < 30.0:
					oks.append("reset_enemy 拉回了出生点（%s）" % str(now_pos.round()))
				else:
					fails.append("★ reset_enemy 没拉回原位：%s vs 期望 %s" % [str(now_pos.round()), str(before_pos.round())])
			else:
				fails.append("目标敌人没有 reset_enemy() 方法")

	# ── ④ Main 的复位流程：只复位"检查点之后"的敌人 ──
	var e1 := scene.get_node_or_null("Enemies/Enemy1") as Node2D
	var e2 := scene.get_node_or_null("Enemies/Enemy2") as Node2D
	if e1 and e2:
		oks.append("Enemy1 x=%.0f   Enemy2 x=%.0f  检查点 x=%.0f" % [e1.global_position.x, e2.global_position.x, cp2.x])
		# 检查点在 1200：两个敌人（760 和 400）都在它左边，所以都不该被复位
		var both_before := e1.global_position.x < cp2.x and e2.global_position.x < cp2.x
		if both_before:
			oks.append("两个敌人都在检查点之前（复位时应保留其死亡状态）")

	# ── 汇总 ──
	for s in oks:
		push_error("  ✓ " + s)
	for s in fails:
		push_error("  ✗ " + s)
	if fails.is_empty():
		push_error("CHECKPOINT_OK 检查点+复位正确（%d 项）" % oks.size())
	else:
		push_error("CHECKPOINT_FAIL 失败 %d 项" % fails.size())
	quit(0 if fails.is_empty() else 1)
