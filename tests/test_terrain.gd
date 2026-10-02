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

	for s in oks:
		push_error("  ✓ " + s)
	for s in fails:
		push_error("  ✗ " + s)
	if fails.is_empty():
		push_error("TERRAIN_OK 地形与背景正确（%d 项）" % oks.size())
	else:
		push_error("TERRAIN_FAIL 失败 %d 项" % fails.size())
	quit(0 if fails.is_empty() else 1)
