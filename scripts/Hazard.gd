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

# ────────────────────────── 可调参数 ──────────────────────────
@export var speed := 150.0              ## 移动速度（px/s）。140~180 是甜点区
@export var travel := 220.0             ## 单程移动距离（px）
@export var vertical := false           ## true = 上下移动，false = 左右移动
@export var start_progress := 0.0       ## 初始相位 0~1（错开多个危险物的节奏）
@export var warn_time := 0.35           ## 启动前的预警闪烁时长（秒）
@export var hazard_size := Vector2(18, 18)  ## 危险区尺寸

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


func _on_body_entered(body: Node2D) -> void:
	# 延迟一帧，和敌人的判死保持一致（给同帧内的玩家攻击留优先权）
	_kill_deferred.call_deferred(body)


func _kill_deferred(body: Node2D) -> void:
	# 向上找组：碰撞体未必就是挂了脚本的那个节点
	var cur: Node = body
	while cur != null:
		if cur.is_in_group("player") and cur.has_method("die"):
			cur.die()
			return
		cur = cur.get_parent()
