extends SceneTree
## 地图生成器 —— 用代码搭出 3 屏关卡
##
## 为什么用生成器而不是手写 .tscn：
##   3 屏地图有 60+ 节点，手写缩进/ID/owner 极易出错；用代码搭还能重复生成，
##   改布局只要改下面的数据表。
##
## ⚠️ 一个已经踩过的巨坑（务必别重犯）：
##   第一版生成器在脚本里动态创建纹理（ImageTexture）赋给 Sprite2D。
##   这种纹理**没有磁盘路径**，PackedScene 只能把整张图**嵌进场景文件**——
##   结果 main.tscn 从 5 KB 涨到 **25 MB**。
##   正确做法：纹理**预先生成为 PNG**，场景只引用路径 + 用 region_rect 裁切。
##
## 布局约束（实测值，不能违反）：
##   • 跳跃高度 ~65 px  -> 平台高度差 ≤ 55 px
##   • 跳跃水平 ~114 px -> 深沟宽度 ≤ 110 px（或给中继平台）
##   • 冲刺水平 ~87 px  -> 冲刺可额外跨越
##
## 用法：Godot --headless --path <项目> --script tools/build_level.gd

const GROUND_TOP := 480.0

const HAZARD := preload("res://scripts/Hazard.gd")
const CHECKPOINT := preload("res://scripts/Checkpoint.gd")
const ENEMY := preload("res://scripts/Enemy.gd")
const PATROL := preload("res://scripts/PatrolEnemy.gd")

const TEX_GROUND := "res://art/kenney/strip_ground.png"
const TEX_PLATFORM := "res://art/kenney/strip_platform.png"
const TEX_ENEMY_SHEET := "res://art/enemy_sheet.png"
const TEX_BG_SKY := "res://art/kenney/bg_sky.png"
const TEX_BG_HILLS := "res://art/kenney/bg_hills.png"
const TEX_BG_TREES := "res://art/kenney/bg_trees.png"

# ─────────────── 地图数据（改这里就是改关卡）───────────────
# 地面段：[起始x, 结束x] —— 段之间的空隙就是深沟
const GROUNDS := [
	[0.0, 960.0],        # 屏1：教学，全程平地
	[960.0, 1090.0],     # 屏2 左半
	[1200.0, 1920.0],    # 屏2 右半（与上段之间 110px 深沟）
	[1920.0, 2880.0],    # 屏3
]
# 平台：[x中心, y中心, 宽度] —— y=440 时离地面 40px，稳稳能跳
const PLATFORMS := [
	[620.0, 440.0, 180.0],     # 屏1
	[1800.0, 440.0, 160.0],    # 屏2 对岸
	[2150.0, 435.0, 150.0],    # 屏3
	[2520.0, 430.0, 140.0],    # 屏3
]
# 检查点：[x] —— 放在每屏入口
const CHECKPOINTS := [140.0, 1000.0, 1960.0]
# 静止敌人：[x, y]
const STATIC_ENEMIES := [
	[700.0, 463.0],      # 屏1：平坦地面，冲过去砍
	[1700.0, 463.0],     # 屏2：对岸
]
# 巡逻敌人：[x, y, 左边界, 右边界]
const PATROLS := [
	[1500.0, 463.0, -110.0, 110.0],   # 屏2：沟后地面巡逻
]
# 移动危险物：[x, y, 行程, 垂直?, 初始相位]
const HAZARDS := [
	[2280.0, 430.0, 190.0, false, 0.0],   # 屏3：左右扫
	[2620.0, 420.0, 110.0, true, 0.5],    # 屏3：上下扫（错开相位）
]


func _initialize() -> void:
	_build.call_deferred()


# ─────────────────────── 工具 ───────────────────────

## 给整棵子树设 owner，否则保存时子节点会丢
func _own(node: Node, owner_node: Node) -> void:
	for c in node.get_children():
		c.owner = owner_node
		_own(c, owner_node)


## 造一块实心地形：StaticBody2D(碰撞) + Sprite2D(视觉，用 region 裁切)
##
## 纹理只引用磁盘 PNG，按需裁切 region —— 场景里不会嵌入像素数据。
func _solid(parent: Node, name: String, cx: float, cy: float, w: float, h: float, tex_path: String) -> void:
	var body := StaticBody2D.new()
	body.name = name
	body.position = Vector2(cx, cy)
	body.collision_layer = 1
	body.collision_mask = 0
	parent.add_child(body)

	var cs := CollisionShape2D.new()
	cs.name = "Shape"
	var rect := RectangleShape2D.new()
	rect.size = Vector2(w, h)
	cs.shape = rect
	body.add_child(cs)

	var sp := Sprite2D.new()
	sp.name = "Visual"
	sp.texture = load(tex_path)
	sp.region_enabled = true
	sp.region_rect = Rect2(0, 0, w, h)
	sp.centered = true
	body.add_child(sp)


## 三层视差背景（解决"画面空旷"）
func _backdrop(parent: Node, tex_path: String, z: int, scale_factor: float, y: float) -> void:
	var layer := ParallaxLayer.new()
	layer.name = "Layer%d" % z
	layer.motion_scale = Vector2(scale_factor, 1.0)
	layer.motion_mirroring = Vector2(960.0, 0.0)   # 水平循环，走到边缘不出空白
	parent.add_child(layer)

	var sp := Sprite2D.new()
	sp.name = "Visual"
	sp.texture = load(tex_path)
	sp.centered = false
	sp.position = Vector2(0, y)
	layer.add_child(sp)


## 敌人视觉（Sprite2D + region 切帧，和旧场景一致）
func _enemy_visual(parent: Node) -> void:
	var sp := Sprite2D.new()
	sp.name = "Visual"
	sp.texture = load(TEX_ENEMY_SHEET)
	sp.region_enabled = true
	sp.region_rect = Rect2(0, 0, 24, 24)
	sp.scale = Vector2(1.5, 1.5)
	parent.add_child(sp)


# ─────────────────────── 主流程 ───────────────────────

func _build() -> void:
	# 从备份起手（干净、稳定），而不是从可能已被改动的当前场景
	var base_path := "res://main_backup.tscn"
	if not FileAccess.file_exists(base_path):
		push_error("GEN_FAIL 找不到基准场景 " + base_path)
		quit(1)
		return

	var scene: Node = (load(base_path) as PackedScene).instantiate()
	root.add_child(scene)

	# ── 清掉一切会由生成器重建的东西 ──
	for path in ["Solids", "Enemies", "Background", "HUD", "ParallaxBg", "Checkpoints", "Hazards"]:
		var n := scene.get_node_or_null(path)
		if n:
			n.free()

	# ═══ 1. 三层视差背景 ═══
	var pb := ParallaxBackground.new()
	pb.name = "ParallaxBg"
	scene.add_child(pb)
	scene.move_child(pb, 0)
	_backdrop(pb, TEX_BG_SKY,   -30, 0.10, 0.0)
	_backdrop(pb, TEX_BG_HILLS, -20, 0.30, 120.0)
	_backdrop(pb, TEX_BG_TREES, -10, 0.55, 0.0)

	# ═══ 2. 地形 ═══
	var solids := Node2D.new()
	solids.name = "Solids"
	scene.add_child(solids)

	for i in range(GROUNDS.size()):
		var g: Array = GROUNDS[i]
		var w: float = g[1] - g[0]
		_solid(solids, "Ground%d" % i, g[0] + w * 0.5, GROUND_TOP + 20.0, w, 40.0, TEX_GROUND)

	for i in range(PLATFORMS.size()):
		var p: Array = PLATFORMS[i]
		_solid(solids, "Platform%d" % i, p[0], p[1], p[2], 22.0, TEX_PLATFORM)

	# ═══ 3. 检查点 ═══
	var cps := Node2D.new()
	cps.name = "Checkpoints"
	scene.add_child(cps)
	for i in range(CHECKPOINTS.size()):
		var area := Area2D.new()
		area.name = "Checkpoint%d" % i
		area.position = Vector2(CHECKPOINTS[i], GROUND_TOP - 30.0)
		area.set_script(CHECKPOINT)
		cps.add_child(area)
		var cs := CollisionShape2D.new()
		cs.name = "Shape"
		var rect := RectangleShape2D.new()
		rect.size = Vector2(36, 120)
		cs.shape = rect
		area.add_child(cs)

	# ═══ 4. 敌人 ═══
	var enemies := Node2D.new()
	enemies.name = "Enemies"
	scene.add_child(enemies)

	# 静止靶子：Node2D(脚本) + Body(StaticBody2D) + Danger(Area2D)
	for i in range(STATIC_ENEMIES.size()):
		var se: Array = STATIC_ENEMIES[i]
		var e := Node2D.new()
		e.name = "Enemy%d" % i
		e.position = Vector2(se[0], se[1])
		e.set_script(ENEMY)
		enemies.add_child(e)

		var body := StaticBody2D.new()
		body.name = "Body"
		body.collision_layer = 4
		body.collision_mask = 0
		e.add_child(body)
		var bs := CollisionShape2D.new()
		bs.name = "Shape"
		var br := RectangleShape2D.new()
		br.size = Vector2(26, 34)
		bs.shape = br
		body.add_child(bs)
		_enemy_visual(body)

		var dg := Area2D.new()
		dg.name = "Danger"
		dg.collision_layer = 0
		dg.collision_mask = 2
		e.add_child(dg)
		var ds := CollisionShape2D.new()
		ds.name = "Shape"
		var dr := RectangleShape2D.new()
		dr.size = Vector2(30, 38)
		ds.shape = dr
		dg.add_child(ds)

	# 巡逻兵（PatrolEnemy 会自己补全缺失的探测节点）
	for i in range(PATROLS.size()):
		var pt: Array = PATROLS[i]
		var pe := CharacterBody2D.new()
		pe.name = "Patrol%d" % i
		pe.position = Vector2(pt[0], pt[1])
		pe.collision_layer = 4
		pe.collision_mask = 1
		pe.set_script(PATROL)
		pe.set("patrol_left", pt[2])
		pe.set("patrol_right", pt[3])
		enemies.add_child(pe)

	# ═══ 5. 移动危险物（让子弹时间有用武之地）═══
	var hzs := Node2D.new()
	hzs.name = "Hazards"
	scene.add_child(hzs)
	for i in range(HAZARDS.size()):
		var hz: Array = HAZARDS[i]
		var h := Area2D.new()
		h.name = "Hazard%d" % i
		h.position = Vector2(hz[0], hz[1])
		h.set_script(HAZARD)
		h.set("travel", hz[2])
		h.set("vertical", hz[3])
		h.set("start_progress", hz[4])
		hzs.add_child(h)
		# ⚠️ 这里**不要**再建 Shape：Hazard.gd 的 _ready() 会自己补全。
		#    原因：set_script() 会**立即触发 _ready()**，那时子节点还没加，
		#    Hazard 以为"没配形状"就自建一个；生成器再加一个就会出现两个碰撞体
		#    （第二个会被 Godot 命名成 @CollisionShape2D@2）。

	# ═══ 6. HUD（Main.gd 需要 HUD/Info 和 HUD/SlowBar）═══
	var hud := CanvasLayer.new()
	hud.name = "HUD"
	scene.add_child(hud)
	var info := Label.new()
	info.name = "Info"
	info.offset_left = 16.0
	info.offset_top = 12.0
	info.offset_right = 760.0
	info.offset_bottom = 42.0
	info.add_theme_font_size_override("font_size", 18)
	hud.add_child(info)

	var bar := Label.new()
	bar.name = "SlowBar"
	bar.offset_left = 16.0
	bar.offset_top = 68.0
	bar.offset_right = 760.0
	bar.offset_bottom = 98.0
	bar.add_theme_font_size_override("font_size", 16)
	hud.add_child(bar)

	# ═══ 7. 玩家（挪到屏1 出生点）═══
	var player := scene.get_node_or_null("Player")
	if player:
		(player as Node2D).position = Vector2(120.0, 400.0)

	# ── 保存 ──
	_own(scene, scene)
	var ps := PackedScene.new()
	var err := ps.pack(scene)
	if err != OK:
		push_error("GEN_FAIL pack 失败 err=%d" % err)
		quit(1)
		return
	var save_err := ResourceSaver.save(ps, "res://main.tscn")
	if save_err == OK:
		push_error("GEN_OK 地图已保存")
	else:
		push_error("GEN_FAIL 保存失败 err=%d" % save_err)
	quit(0)
