extends SceneTree
## 地形纹理验证 —— 确认平铺纹理真的加载了、region 没超出、缩放没被拉伸
##
## 为什么要单独测：
##   ① 文件在磁盘上"存在"不代表 Godot 能加载（换 PNG 后没重新导入会引用到空纹理）
##   ② region 超出贴图范围会画成空白 —— 这个错误**不报错**，只看得出"平台不见了"
##   ③ 平铺纹理的 scale 必须是 1，否则像素被拉伸
##
## ⚠️ 不写死具体宽度/节点数量：地图是生成器产出的，改布局就会变。
##    这里只校验"能加载、region 在范围内、缩放为 1、碰撞盒与视觉一致"。


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var packed: PackedScene = load("res://main.tscn")
	var scene: Node = packed.instantiate()
	root.add_child(scene)
	await physics_frame

	var fails: Array[String] = []
	var oks: Array[String] = []

	var solids := scene.get_node_or_null("Solids")
	if solids == null:
		fails.append("找不到 Solids 节点")
	else:
		var checked := 0
		for child in solids.get_children():
			var body := child as StaticBody2D
			if body == null:
				continue
			var sp := body.get_node_or_null("Visual") as Sprite2D
			if sp == null:
				fails.append("%s 的 Visual 不是 Sprite2D" % body.name)
				continue
			if sp.texture == null:
				fails.append("★ %s 没有贴图（文件存在但没导入？）" % body.name)
				continue
			checked += 1
			var tw := sp.texture.get_width()
			var th := sp.texture.get_height()
			var rr := sp.region_rect
			if rr.size.x > tw + 0.5 or rr.size.y > th + 0.5:
				fails.append("%s 的 region(%.0fx%.0f) 超出贴图(%dx%d) —— 会画成空白" % [
					body.name, rr.size.x, rr.size.y, tw, th])
			if absf(sp.scale.x - 1.0) > 0.01 or absf(sp.scale.y - 1.0) > 0.01:
				fails.append("%s 缩放 %s 不是 1 —— 像素会被拉伸" % [body.name, str(sp.scale)])
			# 碰撞盒要和视觉对得上（否则"看着能站却掉下去"）
			var cs := body.get_node_or_null("Shape") as CollisionShape2D
			if cs and cs.shape is RectangleShape2D:
				var rs: Vector2 = (cs.shape as RectangleShape2D).size
				if absf(rs.x - rr.size.x) > 1.0 or absf(rs.y - rr.size.y) > 1.0:
					fails.append("%s 碰撞盒(%.0fx%.0f) 与视觉 region(%.0fx%.0f) 不一致" % [
						body.name, rs.x, rs.y, rr.size.x, rr.size.y])
		if checked == 0:
			fails.append("★ Solids 下一个带贴图的地形都没有")
		else:
			oks.append("检查了 %d 块地形：贴图已加载、region 在范围内、缩放为 1、碰撞盒一致" % checked)

	# 背景三层也要能加载（否则画面会是纯色，也就是"太空旷"的老问题）
	var pb := scene.get_node_or_null("ParallaxBg")
	if pb == null:
		fails.append("★ 找不到 ParallaxBg（没有视差背景）")
	else:
		var layers := 0
		for child in pb.get_children():
			if not (child is ParallaxLayer):
				continue
			var vis := child.get_node_or_null("Visual") as Sprite2D
			if vis == null or vis.texture == null:
				fails.append("★ 视差层 %s 没有贴图" % child.name)
			else:
				layers += 1
		if layers >= 3:
			oks.append("视差背景 %d 层全部有贴图" % layers)
		elif layers > 0:
			fails.append("视差层只有 %d 层有贴图（期望 3 层）" % layers)

	# ── "能杀人的东西必须有可见视觉"（2026-10-07 用户报的 bug）──
	#
	# 用户原话："全地图最后一个高台的右边，明明空无一物，但是我会被杀。"
	# 根因：生成器造 Hazard 时只造了 Area2D、**没造 Visual 子节点**，
	#       而 Hazard.gd 的 _ready() 只兜底 Shape、不兜底视觉 →
	#       碰撞体在、视觉不在 = **看不见的随机致死**（关卡设计里最忌讳的东西）。
	# ⚠️ 一般化：**场景里凡是能致死的东西，都必须有可见视觉**。
	#    断言故意不写死数量（地图是生成的），只要求"每个 hazard 都有视觉"。
	var hazards := get_nodes_in_group("hazard")
	if hazards.is_empty():
		fails.append("★ 场景里一个危险物都没有（hazard 组为空）—— 生成器没建？")
	else:
		var hz_ok := 0
		for h in hazards:
			var hv := h.get_node_or_null("Visual") as Sprite2D
			if hv == null:
				fails.append("★ 危险物 %s 没有 Visual 子节点 —— 会变成隐形杀手" % h.name)
			elif hv.texture == null:
				fails.append("★ 危险物 %s 的 Visual 没有贴图（新 PNG 没 import？）" % h.name)
			else:
				hz_ok += 1
		if hz_ok == hazards.size():
			oks.append("%d 个危险物都有可见视觉" % hz_ok)

	# ── 世界左右边界墙（用户 2026-10-07）──
	# 没有墙的话玩家能走出地图边缘掉下去 —— 那看起来像"悬崖"，其实是地图没画完。
	# 语义：**边界是墙，沟才是无底洞**（"掉出底部就死"由 Main.gd 的 FALL_DEATH_Y 兜底）。
	# ⚠️ 墙挂在独立的 Bounds 节点下（刻意隐形），所以不会被上面那段 Solids 检查误报。
	var bounds := scene.get_node_or_null("Bounds")
	if bounds == null:
		fails.append("★ 找不到 Bounds —— 世界左右没有边界，玩家会走出地图")
	else:
		var missing_walls: Array[String] = []
		for wn in ["WallLeft", "WallRight"]:
			if bounds.get_node_or_null(wn) == null:
				missing_walls.append(wn)
		if missing_walls.is_empty():
			oks.append("世界左右各有边界墙")
		else:
			fails.append("★ 边界墙缺失：%s" % str(missing_walls))

	for s in oks:
		push_error("  ✓ " + s)
	for s in fails:
		push_error("  ✗ " + s)
	if fails.is_empty():
		push_error("TERRAIN_OK 地形与背景正确（%d 项）" % oks.size())
	else:
		push_error("TERRAIN_FAIL 失败 %d 项" % fails.size())
	quit(0 if fails.is_empty() else 1)
