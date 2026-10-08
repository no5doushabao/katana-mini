extends Area2D
## 移动危险物（Hazard）—— 让"子弹时间"真正有用武之地
##
## 为什么需要它：
##   现在的敌人全是静止靶子，**子弹时间对静止靶子毫无收益**——
##   玩家按住 Shift 只会让自己变慢，于是这个键变成死键。
##   这个来回移动的致命物就是解药：它有"时间窗口"，你必须靠减速来抓准它。
##
## 设计要点（来自关卡设计文档的实测结论）：
##   • 速度 140~180 px/s 是慢动作游戏里的**甜点**（玩家 220 px/s），再快就变弹幕了
##   • 必须给**前摇预警**（启动前闪一下），否则玩家会觉得"随机致死"而不是"我手慢了"
##   • 匀速直线、周期固定 —— **不许有随机性**，随机会把"解谜"变成"抽奖"
##
## 用法：把它放在场景里，配好 patrol 距离即可。碰到玩家 -> 玩家死。

# 视觉贴图（由 tools/gen_hazard_sprite.py 生成）。
# ⚠️ 必须用**磁盘路径 load**，不要用代码动态创建的纹理 —— 动态纹理没有磁盘路径，
#    PackedScene 只能把整张图嵌进场景文件（§8.1 的老坑：main.tscn 会从 5KB 涨到 25MB）。
const TEX_VISUAL := "res://art/hazard.png"

# ────────────────────────── 可调参数 ──────────────────────────
@export var speed := 150.0              ## 移动速度（px/s）。140~180 是甜点区
@export var travel := 220.0             ## 单程移动距离（px）
@export var vertical := false           ## true = 上下移动，false = 左右移动
@export var start_progress := 0.0       ## 初始相位 0~1（错开多个危险物的节奏）
@export var warn_time := 0.35           ## 启动前的预警闪烁时长（秒）
@export var hazard_size := Vector2(18, 18)  ## 危险区尺寸

## 碰到玩家造成的伤害（对应 Player 的 HURT_LARGE 档 = 大伤害）。
## ⚠️ 比杂兵疼得多是**故意的**：危险物有前摇预警（warn_time），玩家有时间躲 ——
##    伤害高才配得上"提前给你预警"。
const HURT_DAMAGE := 6

## true = 每物理帧轮询重叠的玩家（推荐）；false = 只依赖 body_entered。
## ⭐ 理由和敌人那边一样（§2.6 的老 bug）：body_entered 只在"重叠从无到有"
##    那一帧发一次，玩家在危险物身上复活时会拿到"隐形无敌"。
@export var danger_polling := true

# ────────────────────────── 内部状态 ──────────────────────────
var _origin := Vector2.ZERO
var _t := 0.0                ## 0~1 的来回进度（三角波）
var _dir := 1                ## 当前移动方向
var _warn_left := 0.0
var _shape: CollisionShape2D
var _visual: Sprite2D


func _ready() -> void:
	_origin = position
	_t = clampf(start_progress, 0.0, 0.999)
	_warn_left = warn_time

	# 危险区配置：只检测玩家层（第 2 层）
	collision_layer = 0
	collision_mask = 2
	monitoring = true

	_shape = get_node_or_null("Shape") as CollisionShape2D
	_visual = get_node_or_null("Visual") as Sprite2D

	# ⚠️ 兜底：**宁可给个默认视觉，也不要"隐形杀手"**（2026-10-07 的教训）。
	#    用户报的"最后一个高台右边空无一物却会被杀"，根因就是这里 ——
	#    生成器没造 Visual，而 _ready() 原来只兜底 Shape、没兜底视觉。
	#    缺视觉的危险物比缺碰撞体的危险物**危险得多**：后者只是没威胁，
	#    前者是"看不见的随机致死"，正是关卡设计里最忌讳的东西。
	if _visual == null:
		_visual = Sprite2D.new()
		_visual.name = "Visual"
		var tex := load(TEX_VISUAL) as Texture2D
		if tex != null:
			_visual.texture = tex
		add_child(_visual)

	# ⚠️ 只有"缺形状"时才自动补，否则会多出一个重复的 CollisionShape2D
	#    （场景里已经配了 Shape，这里再建一个就会有两个碰撞体叠着）
	if _shape == null:
		_shape = CollisionShape2D.new()
		_shape.name = "Shape"
		var rect := RectangleShape2D.new()
		rect.size = hazard_size
		_shape.shape = rect
		add_child(_shape)
	else:
		if _shape.shape is RectangleShape2D:
			(_shape.shape as RectangleShape2D).size = hazard_size

	add_to_group("hazard")
	body_entered.connect(_on_body_entered)


func _physics_process(delta: float) -> void:
	# ── 前摇：启动前闪一下，给玩家反应时间 ──
	if _warn_left > 0.0:
		_warn_left -= delta
		if _visual:
			# 快速闪烁表示"要动了"
			_visual.modulate.a = 0.35 + 0.65 * absf(sin(_warn_left * 22.0))
		if _warn_left > 0.0:
			return
		if _visual:
			_visual.modulate.a = 1.0

	# ── 三角波来回：匀速、周期固定、无随机 ──
	var step := (speed / maxf(travel, 1.0)) * delta
	_t += step * _dir
	if _t >= 1.0:
		_t = 1.0
		_dir = -1
	elif _t <= 0.0:
		_t = 0.0
		_dir = 1

	var offset := (_t - 0.5) * travel
	position = _origin + (Vector2(0, offset) if vertical else Vector2(offset, 0))

	_poll_danger()


func _on_body_entered(body: Node2D) -> void:
	# 延迟一帧，和敌人的判伤保持一致（给同帧内的玩家攻击留优先权）
	_hit_deferred.call_deferred(body)


## 每物理帧轮询重叠的玩家 —— 兜底判伤（body_entered 管"刚接触"，它管"一直重叠着"）
func _poll_danger() -> void:
	if not danger_polling:
		return
	for body in get_overlapping_bodies():
		if body is Node2D and _find_player_root(body) != null:
			_hit_deferred.call_deferred(body)
			return


## 沿父链向上找玩家根节点（组不会传给子节点，碰撞体未必是挂了脚本的那个节点）
func _find_player_root(node: Node) -> Node:
	var cur: Node = node
	while cur != null:
		if cur.is_in_group("player"):
			return cur
		cur = cur.get_parent()
	return null


func _hit_deferred(body: Node2D) -> void:
	var root := _find_player_root(body)
	if root == null:
		return
	# 优先走血量系统（take_damage）；die() 只作兜底
	if root.has_method("take_damage"):
		root.take_damage(HURT_DAMAGE)
	elif root.has_method("die"):
		root.die()
