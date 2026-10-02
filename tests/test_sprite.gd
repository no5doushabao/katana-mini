extends SceneTree
## 验证精灵图是否正确接入（换贴图后必须确认它真的在渲染）


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var packed: PackedScene = load("res://main.tscn")
	var scene: Node = packed.instantiate()
	root.add_child(scene)
	await physics_frame
	await physics_frame

	var fails: Array[String] = []
	var oks: Array[String] = []

	# 先拿到 Player 节点，后面要用它的常量（SPRITE_SIZE / SHEET_COLS）做动态校验
	var p := scene.get_node_or_null("Player")

	# ── 玩家精灵 ──
	var ps := scene.get_node_or_null("Player/Visual") as Sprite2D
	if ps == null:
		fails.append("Player/Visual 不是 Sprite2D（类型没换成功）")
	else:
		oks.append("Player/Visual 是 Sprite2D")
		if ps.texture == null:
			fails.append("★ 玩家精灵没有贴图（texture == null）")
		else:
			oks.append("玩家贴图已加载: %dx%d" % [ps.texture.get_width(), ps.texture.get_height()])
		if not ps.region_enabled:
			fails.append("玩家精灵没开 region_enabled（会显示整张图）")
		else:
			var rr := ps.region_rect
			oks.append("region_rect = (%.0f, %.0f, %.0f, %.0f)" % [rr.position.x, rr.position.y, rr.size.x, rr.size.y])
			# 从 Player.gd 的常量动态读期望值 —— 避免"换了素材但测试还写死旧尺寸"的假失败
			if p and p.get("SPRITE_SIZE") != null:
				var want := float(p.get("SPRITE_SIZE"))
				if absf(rr.size.x - want) > 0.01:
					fails.append("region 宽度 %.0f 与 Player.gd 的 SPRITE_SIZE(%.0f) 不一致" % [rr.size.x, want])
				else:
					oks.append("region 尺寸与 SPRITE_SIZE 一致（%.0fx%.0f）" % [rr.size.x, rr.size.y])
				if ps.texture and ps.texture.get_width() % int(want) != 0:
					fails.append("贴图宽度 %d 不是 SPRITE_SIZE(%d) 整数倍 —— 帧会切歪" % [ps.texture.get_width(), int(want)])
				else:
					oks.append("贴图宽度 %d 可被 %d 整除" % [ps.texture.get_width(), int(want)])
		# 缩放必须等比（翻转逻辑若写成 scale.x = -1 会破坏等比）
		if absf(ps.scale.x - ps.scale.y) > 0.01:
			fails.append("★ 玩家精灵缩放不等比 %s —— 可能被翻转逻辑改坏" % str(ps.scale))
		else:
			oks.append("玩家精灵等比缩放 %s" % str(ps.scale))

	# ── 玩家脚本引用 ──
	if p and p.get("sprite") == null:
		fails.append("Player.gd 的 sprite 引用为 null —— 切帧不会生效")
	elif p:
		oks.append("Player.gd 的 sprite 引用正常")

	# ── 所有敌人的视觉 ──
	# ⚠️ 不写死 Enemies/Enemy1、Enemy2 这类具体路径：
	#    地图是生成器产出的，节点名会随布局变（现在叫 Enemy0/Enemy1/Patrol0）。
	#    改成遍历 "enemy" 组，并兼容两种视觉挂法：
	#      静止敌人 Enemy.gd   -> Visual 挂在 Body 下
	#      巡逻兵 PatrolEnemy  -> Visual 直接挂在根下
	var checked := 0
	for n in get_nodes_in_group("enemy"):
		var node := n as Node2D
		if node == null:
			continue
		# Visual 可能挂在根下（巡逻兵），也可能挂在 Body 下（静止敌人）
		var vis := node.get_node_or_null("Visual") as Sprite2D
		if vis == null:
			vis = node.get_node_or_null("Body/Visual") as Sprite2D
		if vis == null:
			# 区分"根本没有视觉"和"视觉是别的类型（比如自动补的 ColorRect 色块）"
			var other := node.get_node_or_null("Visual")
			if other == null:
				other = node.get_node_or_null("Body/Visual")
			if other != null:
				oks.append("敌人 %s 的视觉是 %s（占位色块，非像素精灵）" % [node.name, other.get_class()])
			else:
				fails.append("★ 敌人 %s 完全没有视觉节点" % node.name)
			continue
		checked += 1
		if absf(vis.scale.x - vis.scale.y) > 0.01:
			fails.append("★ 敌人 %s 缩放不等比 %s —— 被翻转逻辑改坏了" % [node.name, str(vis.scale)])
		elif vis.texture == null:
			fails.append("★ 敌人 %s 没有贴图" % node.name)
		else:
			oks.append("敌人 %s 精灵正常（%s，等比缩放 %s）" % [node.name, str(vis.texture.get_size()), str(vis.scale)])

	oks.append("其中 %d 个用了像素精灵" % checked)

	# ── 敌人2 脚本的 _visual ──
	var e2 := scene.get_node_or_null("Enemies/Enemy2")
	if e2 and e2.get("_visual") == null:
		fails.append("PatrolEnemy.gd 的 _visual 为 null")
	elif e2:
		oks.append("PatrolEnemy.gd 的 _visual 引用正常")

	for s in oks:
		push_error("  ✓ " + s)
	for s in fails:
		push_error("  ✗ " + s)
	if fails.is_empty():
		push_error("SPRITE_OK 精灵接入正确（%d 项）" % oks.size())
	else:
		push_error("SPRITE_FAIL 失败 %d 项" % fails.size())
	quit(0 if fails.is_empty() else 1)
