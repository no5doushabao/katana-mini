extends CharacterBody2D
## 玩家控制器 —— 迷刀 Mini 的核心手感所在
##
## 设计意图（照抄《武士刀零》的关键手感，不是照抄它的全部）：
##   1. 移动响应要快：加速度高，但松手有点刹车感，不是瞬停
##   2. 跳跃要宽容：土狼时间（coyote time）+ 输入缓冲（jump buffer）+
##      可变跳跃高度（早松手跳得矮）
##   3. 冲刺是灵魂：短、快、有无敌帧，用冷却限制不能连按
##   4. 一击必杀：敌人碰你就死，死了立刻回检查点（重开零成本）

# ────────────────────────────── 手感参数（你要调的就是这些）──────────────────────────────
# 想调手感时，只改这一块，别动下面的逻辑。

const SPEED := 220.0              ## 水平最大速度
const ACCEL_GROUND := 2400.0      ## 地面加速度（越大越"跟手"）
const ACCEL_AIR := 1600.0         ## 空中加速度（比地面小，空中要有点惯性）
const FRICTION_GROUND := 2800.0   ## 地面松手减速（刹车感）
const FRICTION_AIR := 600.0       ## 空中松手减速（几乎不减速）

const JUMP_VELOCITY := -430.0     ## 跳跃初速度（负数向上）
const GRAVITY := 1500.0           ## 重力加速度
const MAX_FALL_SPEED := 900.0     ## 最大下落速度（防止穿墙，也防止"炮弹感"）
const JUMP_CUT_MULT := 0.45       ## 早松手时把上升速度乘这个数 -> 跳得矮

const COYOTE_TIME := 0.12         ## 离开平台后仍可跳的宽限时间（秒）
const JUMP_BUFFER := 0.12         ## 落地前提前按跳，仍会生效的宽限时间

const DASH_SPEED := 620.0         ## 冲刺速度
const DASH_TIME := 0.14           ## 冲刺持续（秒）
const DASH_COOLDOWN := 0.32       ## 冲刺冷却（秒）

const ATTACK_COOLDOWN := 0.26     ## 攻击冷却
const ATTACK_ACTIVE := 0.10       ## 攻击判定框存在时长
const ATTACK_RANGE := Vector2(52.0, 34.0)  ## 判定框尺寸

# ── 精灵图帧索引（player_sheet.png 是 5 列 x 2 行，每帧 24x24）──
# 素材来源：Kenney "Pixel Platformer"（CC0），角色 tile_0009。
# 原图是**静态单帧**，动作用像素位移生成（见 art/kenney/ 与生成脚本）。
# 改精灵图后，这里和 main.tscn 的 region_rect 都要同步。
const FR_IDLE := [0, 1]        ## 待机 2 帧（上浮呼吸）
const FR_RUN := [2, 3, 4, 5]   ## 跑动 4 帧（左右倾 + 上浮）
const FR_JUMP := 6             ## 起跳
const FR_FALL := 7             ## 下落
const FR_ATTACK := [8, 9]      ## 挥刀 2 帧（蓄力 + 前冲）
const SHEET_COLS := 5          ## 精灵图列数（算 region_rect 用）
const SPRITE_SIZE := 24        ## 单帧像素尺寸（Kenney 图块是 24x24）

const RUN_FPS := 12.0          ## 跑动动画速度（帧/秒）
const IDLE_FPS := 4.0          ## 待机动画速度（慢一点，像在呼吸）

# ── 子弹时间（按住 Shift）──
# 实现原理：Engine.time_scale 会把"世界时间"整体放慢，
# 敌人的移动、tween 动画、物理计时全都会跟着变慢。
# 但玩家想保持原速，所以要把玩家速度按 1/time_scale 放大补偿回去。
const SLOW_SCALE := 0.30          ## 世界时间降到 30%
const SLOW_LERP := 8.0            ## 进出慢动作的平滑速度（越大切换越干脆）
const SLOW_ENERGY_MAX := 1.6      ## 能量条满值（单位：秒）
const SLOW_DRAIN := 1.0           ## 每秒消耗
const SLOW_REGEN := 0.55          ## 每秒恢复（比消耗慢，所以不能一直开）

## 玩家速度补偿系数：1.0 = 不补偿（玩家也变慢），0.0 = 完全补偿（玩家保持原速）
## 这是子弹时间手感最关键的旋钮，试着改成 0.5 感受区别
const SLOW_PLAYER_SPEED_KEEP := 0.0

# ────────────────────────────── 内部状态 ──────────────────────────────

var facing := 1                   ## 1 = 朝右, -1 = 朝左
var _coyote := 0.0                ## 剩余土狼时间
var _jump_buffer := 0.0           ## 剩余跳跃缓冲时间
var _dash_left := 0.0             ## 剩余冲刺时间
var _dash_cd := 0.0               ## 剩余冷却
var _attack_cd := 0.0             ## 剩余攻击冷却
var _attack_left := 0.0           ## 攻击判定框剩余存在时间
var _is_dead := false
var _slow_energy := SLOW_ENERGY_MAX  ## 子弹时间能量（满值开始）

@onready var shape: CollisionShape2D = $Shape
@onready var attack_area: Area2D = $AttackArea
@onready var camera: Camera2D = get_node_or_null("Camera2D") as Camera2D
@onready var sprite: Sprite2D = get_node_or_null("Visual") as Sprite2D

var _anim_time := 0.0          ## 动画计时器（累加 delta）

func _ready() -> void:
	add_to_group("player")
	# 攻击判定框罩住敌人时，由这里负责"击杀"。
	# 注意：Area2D 自己只会"知道有东西在里面"，不会做任何事——
	# 必须有人接收信号并执行后果，否则就是"检测到了但没人管"。
	attack_area.body_entered.connect(_on_attack_hit)

func _physics_process(delta: float) -> void:
	# 精灵切帧放最前面：即使死了也要把帧摆对（死亡状态显示下落帧）
	_update_sprite(delta)
	if _is_dead:
		return

	_tick_timers(delta)
	_update_bullet_time(delta)
	_handle_horizontal(delta)
	_handle_dash(delta)
	_handle_jump(delta)
	_handle_attack(delta)

	# 重力和下落上限
	if not is_on_floor():
		velocity.y = minf(velocity.y + GRAVITY * delta, MAX_FALL_SPEED)
	elif _dash_left <= 0.0 and velocity.y > 0.0:
		velocity.y = 0.0

	move_and_slide()

# ────────────────────────────── 各子系统 ──────────────────────────────

func _tick_timers(delta: float) -> void:
	_dash_cd = maxf(_dash_cd - delta, 0.0)
	_attack_cd = maxf(_attack_cd - delta, 0.0)
	_attack_left = maxf(_attack_left - delta, 0.0)
	_jump_buffer = maxf(_jump_buffer - delta, 0.0)

	if is_on_floor():
		_coyote = COYOTE_TIME
	else:
		_coyote = maxf(_coyote - delta, 0.0)

	# 攻击判定框只在有效期内开启。
	# 每次攻击都是 false -> true 的一次跳变，所以 body_entered 每次都会重新触发，
	# 不会出现"第二次砍同一个敌人没反应"的问题。
	attack_area.monitoring = _attack_left > 0.0

	# 判定框始终贴着面朝方向那一侧。
	# ⚠️ 这里以前误写成 `if _attack_left > 0.0:`，导致**只有攻击那 0.1 秒内**
	#    位置才会更新，平时框会冻在最后一次攻击的位置——转身时不跟着转。
	attack_area.position.x = absf(attack_area.position.x) * facing


## 攻击框罩住敌人时的回调：一击必杀
##
## ⚠️ 踩过的坑：Godot 的组**不会**传递给子节点。
## 碰撞检测返回的是碰撞体本身（敌人的 Body 子节点），
## 而 add_to_group("enemy") 加在 Enemy1（父节点）上——两者对不上。
## 所以必须向上追溯节点树去找组，不能只判断碰撞体自己。
func _on_attack_hit(body: Node2D) -> void:
	var root := _find_group_ancestor(body, "enemy")
	if root and root.has_method("kill"):
		root.kill()


## 沿父节点链向上找第一个属于指定组的节点（含自身）
func _find_group_ancestor(node: Node, group: String) -> Node:
	var cur: Node = node
	while cur != null:
		if cur.is_in_group(group):
			return cur
		cur = cur.get_parent()
	return null


## 子弹时间：按住 Shift 把世界放慢
##
## 关键在于"补偿"：世界慢下来后，玩家的速度要用 1/time_scale 放大，
## 才能在屏幕上保持原来的移动速度。这样玩家相对敌人才是"变快"了，
## 而不是大家一起变慢（那就只是卡顿）。
func _update_bullet_time(delta: float) -> void:
	var want := Input.is_action_pressed("slow") and _slow_energy > 0.0 and not _is_dead

	if want:
		_slow_energy = maxf(_slow_energy - SLOW_DRAIN * delta, 0.0)
	else:
		_slow_energy = minf(_slow_energy + SLOW_REGEN * delta, SLOW_ENERGY_MAX)

	var target_scale := SLOW_SCALE if want else 1.0
	# 用指数平滑过渡，避免时间尺度瞬变造成抖动
	var new_scale: float = lerpf(Engine.time_scale, target_scale, clampf(SLOW_LERP * delta, 0.0, 1.0))
	if absf(new_scale - target_scale) < 0.005:
		new_scale = target_scale
	Engine.time_scale = clampf(new_scale, 0.01, 2.0)

	# 镜头反馈：慢动作时轻微推近，强化"聚焦"的感觉
	if camera:
		var depth := (1.0 - Engine.time_scale) / (1.0 - SLOW_SCALE)
		camera.zoom = Vector2.ONE * (1.0 + 0.10 * depth)


## 子弹时间下给玩家速度做补偿放大
func _time_compensation() -> float:
	var keep := 1.0 - SLOW_PLAYER_SPEED_KEEP
	return 1.0 + keep * (1.0 / Engine.time_scale - 1.0)


func _handle_horizontal(delta: float) -> void:
	# 冲刺用固定速度，也要按同样的比例补偿
	if _dash_left > 0.0:
		velocity.x = DASH_SPEED * facing * _time_compensation()
		return

	var comp := _time_compensation()
	var dir := Input.get_axis("move_left", "move_right")
	if absf(dir) > 0.01:
		var new_facing := 1 if dir > 0.0 else -1
		if new_facing != facing:
			facing = new_facing
			# 立即把攻击框挪到新的面朝方向
			attack_area.position.x = absf(attack_area.position.x) * facing
			# ⚠️ 必须重绘：Godot 的 _draw() 只在 queue_redraw() 之后重画一次，
			#    不主动调用的话，调试框会一直停在旧位置（转身了也不动）。
			queue_redraw()
		velocity.x = move_toward(velocity.x, dir * SPEED * comp, ACCEL_GROUND * comp * delta)
	else:
		# 空中减速比地面慢，保住一点惯性
		var fric := FRICTION_GROUND if is_on_floor() else FRICTION_AIR
		velocity.x = move_toward(velocity.x, 0.0, fric * comp * delta)


func _handle_dash(delta: float) -> void:
	if Input.is_action_just_pressed("dash") and _dash_cd <= 0.0:
		_dash_left = DASH_TIME
		_dash_cd = DASH_COOLDOWN

	if _dash_left > 0.0:
		_dash_left -= delta
		# 冲刺期间无视重力（这是"悬浮感"的来源）
		velocity.y = 0.0


func _handle_jump(delta: float) -> void:
	if Input.is_action_just_pressed("jump"):
		_jump_buffer = JUMP_BUFFER

	if _jump_buffer > 0.0 and _coyote > 0.0:
		velocity.y = JUMP_VELOCITY
		_jump_buffer = 0.0
		_coyote = 0.0

	# 可变跳跃高度：上升途中松手 -> 立刻削减上升速度
	if velocity.y < 0.0 and not Input.is_action_pressed("jump"):
		velocity.y *= JUMP_CUT_MULT


func _handle_attack(_delta: float) -> void:
	if Input.is_action_just_pressed("attack") and _attack_cd <= 0.0:
		_attack_cd = ATTACK_COOLDOWN
		_attack_left = ATTACK_ACTIVE


## 被任何危险物（敌人、陷阱）碰到时由它们调用
func die() -> void:
	if _is_dead:
		return
	_is_dead = true
	velocity = Vector2.ZERO
	# 交给主场景处理"重开"，玩家自己不管关卡逻辑
	get_tree().call_group("level", "on_player_died")


## 复活：回到检查点
func respawn(at: Vector2) -> void:
	global_position = at
	velocity = Vector2.ZERO
	_is_dead = false
	_dash_left = 0.0
	_dash_cd = 0.0
	_attack_left = 0.0


## 根据当前状态切换精灵帧
##
## 优先级（高 -> 低）：攻击 > 冲刺 > 空中 > 跑动 > 待机
## 用一张精灵图 + region_rect 手动切帧，不用 AnimatedSprite2D：
## 因为我们的状态切换是"代码决定放哪一帧"，手动切最直接、最好调试。
func _update_sprite(delta: float) -> void:
	if sprite == null:
		return

	var frame := FR_IDLE[0]
	var fps := IDLE_FPS

	if _attack_left > 0.0:
		# 攻击：两帧平均分布在整个判定窗口里
		var t := 1.0 - (_attack_left / ATTACK_ACTIVE)
		frame = FR_ATTACK[0] if t < 0.5 else FR_ATTACK[1]
	elif _dash_left > 0.0:
		frame = FR_RUN[1]          # 冲刺用固定的一个跑姿，表示"冲出去了"
	elif not is_on_floor():
		frame = FR_JUMP if velocity.y < 0.0 else FR_FALL
	elif absf(velocity.x) > 12.0:
		fps = RUN_FPS
		_anim_time += delta
		frame = FR_RUN[int(_anim_time * fps) % FR_RUN.size()]
	else:
		_anim_time += delta
		frame = FR_IDLE[int(_anim_time * fps) % FR_IDLE.size()]

	# 精灵图是 5 列网格，按索引反算它在第几行第几列
	sprite.region_rect = Rect2(
		(frame % SHEET_COLS) * SPRITE_SIZE,
		(frame / SHEET_COLS) * SPRITE_SIZE,
		SPRITE_SIZE, SPRITE_SIZE)

	# ⚠️ 这里的翻转方向是"反"的，而且是有意的 —— 用户反馈过"主角在倒车"。
	#
	# 根因：Kenney `Pixel Platformer` 的角色是**正面视图**（脸朝镜头、左右对称），
	#       它根本没有"朝左/朝右"的区分。无脑镜像会让人觉得"转过身去/倒着走"。
	#       横版动作游戏应该用**侧面视图**的素材。
	#
	# 权宜之计：把翻转反过来，让"看起来的朝向"和按键方向一致。
	# 根治方案：换侧面视图素材（`new-platformer` 包已在
	# `Kenney New Platformer`，有 idle/walk/jump 完整 9 帧 + XML 图集坐标）。
	# 换素材时**这一行要改回 `facing < 0`**。
	sprite.flip_h = facing > 0


## 把攻击判定框画出来，方便调试时看见它到底在哪
##
## ⚠️ 这个绘制曾经有个 bug：朝右时从 y=0 起画、朝左时从 y=-17 起画，
##    于是框在两种朝向下垂直位置差 34px（朝右看着"偏下/矮一截"）。
##    而**真实碰撞判定一直是居中的**（AttackArea 在 position=(±33, 0)、
##    形状 52x34）——所以那个 bug 只骗眼睛，不影响手感。
##    教训：调试可视化必须和真实判定用同一套坐标，否则会误导判断。
func _draw() -> void:
	# 矩形始终以玩家原点为中心，只按朝向水平翻转
	var x0 := 0.0 if facing > 0 else -ATTACK_RANGE.x
	var r := Rect2(Vector2(x0, -ATTACK_RANGE.y * 0.5), ATTACK_RANGE)
	var col := Color(1.0, 0.85, 0.2, 0.35) if _attack_left > 0.0 else Color(1, 1, 1, 0.06)
	draw_rect(r, col, true)
