extends CharacterBody2D
## 巡逻敌人（会移动的版本）—— 在两个 x 坐标之间来回走
##
## ══════════════════ 为什么用 CharacterBody2D，而不是 StaticBody2D + 手动改 position ══════════════════
## 1. **不会穿墙**：move_and_slide() 是"扫掠式"移动 —— 它按运动路径做形状检测，
##    所以速度再快也停得住（实测 6000 px/s 撞 20px 厚的墙也不会穿过去）。
##    而 StaticBody2D 手动改 position 相当于"瞬移"：物理服务器只看见两个相距很远的
##    离散位置，中间过程不存在，薄地形、玩家、判定区都可能被直接跳过。
## 2. **免费得到 is_on_floor() / is_on_wall()**：巡逻掉头和"前方没路"全靠这两个状态。
##    StaticBody2D 完全没有这些概念，你得自己写射线去模拟。
## 3. **StaticBody2D 的语义就是"不动的世界几何"**：它的碰撞信息是按静态优化的，
##    每帧移动它会让物理服务器反复更新 AABB，性能与正确性都不划算。
## 4. **以后要加东西时不至于重写**：跳跃巡逻、斜坡行走、被击退、顶到天花板……
##    CharacterBody2D 全都现成；StaticBody2D 每一条都要手写。
##
## 【唯一应该换掉的场合】如果要让玩家能"站在敌人头上被带着走"，那属于移动平台的活，
## 应该用 AnimatableBody2D（sync_to_physics 默认为 true，会正确携带站在上面的物体）。
## 但"一击必杀"的游戏里玩家不该能踩在敌人身上，所以这里 CharacterBody2D 是对的。
##
## ══════════════════ 节点结构（本脚本挂根节点）══════════════════
## PatrolEnemy (CharacterBody2D)   ← 本脚本；collision_layer = 第3层(enemy)，mask = 第1层(world)
## ├── Shape      (CollisionShape2D)  身体碰撞；被玩家 AttackArea 检测到就算"被砍中"
## ├── Visual     (ColorRect)         色块占位图
## ├── LedgeProbe (RayCast2D)         朝下前方探测"脚下有没有地"（防掉崖）——缺了会自动创建
## ├── Sight      (RayCast2D)         视线检测（可选，缺了会自动创建）
## └── Danger     (Area2D)            罩住玩家的危险区；mask = 第2层(player) ——缺了会自动创建
##     └── Shape  (CollisionShape2D)
##
## ⚠️ 物理层最容易搞错的一点：编辑器里的"层号"和 .tscn 里的 collision_layer 数值不是一回事。
##    第 3 层的**位值**是 1<<2 = 4。本项目 README 的表格用的是层号，
##    而 main.tscn 里写的是 `collision_layer = 4`（位值）——两者说的是同一件事，别混。
##    代码里推荐用 set_collision_layer_value(层号, true)，它按**层号**工作（从 1 开始）。
##    ⚠️ 而且 CharacterBody2D **默认 collision_layer = 1**（世界层）！
##    如果只写 set_collision_layer_value(3, true)，结果是 1|4 = 5 ——
##    敌人就同时属于"世界"层，而玩家 mask=1，于是玩家会撞上一堵看不见的墙。
##    所以下面 _apply_layers() 里第一步就是先把第 1 层关掉。

signal died   ## 死亡信号（Main.gd 用它计分）

enum State { PATROL, TURN_PAUSE, IDLE, CHASE }

const GROUP_ENEMY := "enemy"
const GROUP_PLAYER := "player"

# ────────────────────────────── 可调参数（在检查器里改，不用碰代码）──────────────────────────────

@export_group("巡逻范围")
## 巡逻左边界（相对出生点的 x 偏移，负数在左）
@export var patrol_left := -96.0
## 巡逻右边界（相对出生点的 x 偏移，正数在右）
@export var patrol_right := 96.0

@export_group("速度")
@export var patrol_speed := 70.0        ## 巡逻速度（像素/秒）
@export var chase_speed := 110.0        ## 追击速度（要比巡逻快一点才有压迫感）
@export var turn_pause := 0.25          ## 掉头时的停顿（秒）；0 = 立刻转身，会显得很机械
@export var gravity := 1500.0           ## ⚠️ 必须和 Player.gd 的 GRAVITY 保持一致！
@export var max_fall_speed := 900.0

@export_group("地面探测")
@export var ledge_probe_depth := 14.0   ## 向下探多深算"有地"（调大可容忍小台阶/斜坡）
@export var ledge_probe_forward := 0.0  ## 探针前伸距离；0 = 自动用"半个身体宽 + 2"
@export var auto_build_probes := true   ## 场景里缺探针节点时用代码补上（方便脚本生成敌人）

@export_group("玩家检测 / 追击")
@export var can_chase := true           ## 关掉就退化成"纯巡逻兵"
@export var sight_distance := 180.0     ## 视线长度（只在朝向前方发射）
@export var lose_sight_time := 0.8      ## 看不见玩家后还追多久（秒）
@export var chase_stop_distance := 6.0  ## 贴到这么近就不再推进（避免在玩家身上抖）

@export_group("危险区判定（一击必杀）")
## true = 每物理帧检查一次危险区里的玩家（推荐）
## false = 只依赖 Danger 的 body_entered 信号（敌人不动时够用，移动时会出问题）
##
## 为什么推荐轮询：body_entered 只在"重叠状态从无到有"那一帧发一次。
## 玩家在敌人身上复活、或者被别的东西推回来，重叠状态没变化 -> 信号不再发，
## 于是玩家获得"隐形无敌"（实测：站在敌人身体里却不会被判死）。
## 每帧轮询 get_overlapping_bodies() 没有这个问题，代价是每个敌人每帧一次列表查询。
@export var danger_polling := true

# ────────────────────────────── 内部状态 ──────────────────────────────

var _dead := false
var _state := State.PATROL
var _facing := 1                 ## 1 = 朝右，-1 = 朝左
var _move_dir := 1               ## 本帧的水平移动方向（-1/0/1）
var _turn_timer := 0.0
var _lost_timer := 0.0           ## 还有多久彻底放弃追击
var _seen_player: Node2D = null
var _kill_pending := false       ## 已经排了一次"判玩家死"，避免每帧重复排队
var _spawn_position := Vector2.ZERO
var _left_x := 0.0               ## 巡逻左边界的世界坐标
var _right_x := 0.0              ## 巡逻右边界的世界坐标
var _body_size := Vector2(26.0, 34.0)
var _probe_forward := 15.0

@onready var _shape: CollisionShape2D = get_node_or_null("Shape") as CollisionShape2D
@onready var _visual: CanvasItem = get_node_or_null("Visual") as CanvasItem
@onready var _danger: Area2D = get_node_or_null("Danger") as Area2D
@onready var _ledge_probe: RayCast2D = get_node_or_null("LedgeProbe") as RayCast2D
@onready var _sight: RayCast2D = get_node_or_null("Sight") as RayCast2D


func _ready() -> void:
	add_to_group(GROUP_ENEMY)
	_read_body_size()      # 先拿到身体尺寸，自动补的 Danger 区要用它
	_ensure_probes()       # 再补齐缺失的探针 / Danger 节点
	_ensure_visual()       # 缺视觉节点时补一个精灵（否则巡逻兵完全看不见）
	_apply_layers()        # ⚠️ 必须在 _ensure_probes() 之后：否则新建的 Danger 区拿不到物理层
	_configure_probes()

	_spawn_position = global_position
	_left_x = _spawn_position.x + minf(patrol_left, patrol_right)
	_right_x = _spawn_position.x + maxf(patrol_left, patrol_right)

	if _danger:
		_danger.body_entered.connect(_on_danger_body_entered)

	_sync_visual()


## 缺视觉节点时自动补一个像素精灵
##
## 原来这里什么也不做，于是用代码生成的巡逻兵**完全没有视觉**
## （场景里没配 Visual，脚本也不补）——看上去就是"敌人凭空消失"。
func _ensure_visual() -> void:
	if _visual != null:
		return
	var sheet := load("res://art/enemy_sheet.png") as Texture2D
	if sheet == null:
		return
	var sp := Sprite2D.new()
	sp.name = "Visual"
	sp.texture = sheet
	sp.region_enabled = true
	sp.region_rect = Rect2(0, 0, 24, 24)
	sp.scale = Vector2(1.5, 1.5)
	add_child(sp)
	_visual = sp


## 物理层设置。注意顺序：**先清空**再设，否则会保留 CharacterBody2D 默认的第 1 层。
func _apply_layers() -> void:
	collision_layer = 0                            # 清掉默认的"世界"层
	set_collision_layer_value(3, true)             # 第 3 层 = enemy（供玩家 AttackArea 检测）
	collision_mask = 0
	set_collision_mask_value(1, true)              # 只和"世界"碰撞：不会被玩家推动/卡住

	if _danger:
		_danger.collision_layer = 0
		_danger.collision_mask = 0
		_danger.set_collision_mask_value(2, true)  # 只检测第 2 层 = player


## 用 Shape 的实际尺寸校准探针位置，省得你在两处手工同步数字
func _read_body_size() -> void:
	if _shape and _shape.shape is RectangleShape2D:
		_body_size = (_shape.shape as RectangleShape2D).size


func _ensure_probes() -> void:
	if _ledge_probe == null and auto_build_probes:
		_ledge_probe = RayCast2D.new()
		_ledge_probe.name = "LedgeProbe"
		add_child(_ledge_probe)
	if _sight == null and auto_build_probes:
		_sight = RayCast2D.new()
		_sight.name = "Sight"
		add_child(_sight)
	if _danger == null and auto_build_probes:
		_danger = Area2D.new()
		_danger.name = "Danger"
		var dc := CollisionShape2D.new()
		dc.name = "Shape"
		var dr := RectangleShape2D.new()
		dr.size = _body_size + Vector2(4.0, 4.0)   # 危险区比身体略大一点，容错
		dc.shape = dr
		_danger.add_child(dc)
		add_child(_danger)


## 探针的位置/朝向全部由参数算出来，节点只要存在就行
func _configure_probes() -> void:
	var half := _body_size * 0.5
	_probe_forward = ledge_probe_forward if ledge_probe_forward > 0.0 else half.x + 2.0

	if _ledge_probe:
		_ledge_probe.enabled = true
		_ledge_probe.position = Vector2(_probe_forward, half.y - 2.0)  # 脚底前方一点
		_ledge_probe.target_position = Vector2(0.0, ledge_probe_depth)  # 朝下探
		_ledge_probe.hit_from_inside = false
		_ledge_probe.collide_with_areas = false   # 只关心实体地形，别被别人的判定区干扰
		_ledge_probe.collide_with_bodies = true
		_ledge_probe.collision_mask = 0
		_ledge_probe.set_collision_mask_value(1, true)   # 第 1 层 = world

	if _sight:
		_sight.enabled = true
		_sight.position = Vector2(0.0, -half.y * 0.25)   # 大概"眼睛"的高度
		_sight.hit_from_inside = false
		_sight.collide_with_areas = false
		_sight.collision_mask = 0
		_sight.set_collision_mask_value(1, true)   # world：用来判断"有没有被墙挡住"
		_sight.set_collision_mask_value(2, true)   # player：第一命中是玩家 = 看得见


# ────────────────────────────── 主循环 ──────────────────────────────

func _physics_process(delta: float) -> void:
	if _dead:
		return

	_update_sight(delta)
	_think(delta)
	_move(delta)
	_poll_danger()
	queue_redraw()   # 调试可视化用（_draw 里的巡逻范围/朝向）


## 每物理帧检查危险区里有没有玩家。
## 注意 get_overlapping_bodies() 读到的是**物理服务器本帧**算出来的重叠状态，
## 也就是"这一帧进来"最迟下一帧一定被看到 —— 对一击必杀完全够用（延迟 16ms）。
func _poll_danger() -> void:
	if not danger_polling or _dead or _kill_pending:
		return
	if _danger == null or not is_instance_valid(_danger) or not _danger.monitoring:
		return
	for body in _danger.get_overlapping_bodies():
		if body is Node2D and _is_in_group_upwards(body, GROUP_PLAYER):
			_kill_pending = true
			# 仍然用 call_deferred：把"判玩家死"推到帧末，
			# 这样同一帧里"玩家先砍中敌人"永远优先成立（避免同归于尽）。
			_kill_player_deferred.call_deferred(body)
			return


func _think(delta: float) -> void:
	match _state:
		State.PATROL:
			_move_dir = _facing
			# ① 到达巡逻边界 -> 掉头
			if (_facing > 0 and global_position.x >= _right_x) \
					or (_facing < 0 and global_position.x <= _left_x):
				_start_turn()
			# ② 前方脚下没地 -> 掉头（这就是"走到平台边缘停下来"）
			elif _no_ground_ahead(_facing):
				_start_turn()

		State.TURN_PAUSE:
			_move_dir = 0
			_turn_timer -= delta
			if _turn_timer <= 0.0:
				_state = State.PATROL

		State.IDLE:
			# 两侧都没地面（站在比身体还窄的柱子上）：原地站着，别抽筋
			_move_dir = 0
			if not _no_ground_ahead(_facing):
				_state = State.TURN_PAUSE
				_turn_timer = turn_pause

		State.CHASE:
			_think_chase()


func _think_chase() -> void:
	var target := _seen_player
	if not is_instance_valid(target):
		_end_chase()
		return

	var dx := target.global_position.x - global_position.x
	if absf(dx) <= chase_stop_distance:
		_move_dir = 0
		return

	_move_dir = 1 if dx > 0.0 else -1
	_facing = _move_dir

	# ⚠️ 追击时**必须**继续做边缘检测，否则敌人会为了追你直接跳下平台。
	# 这里的选择是"刹在崖边"（也可以改成 -_move_dir 掉头，看你要什么行为）。
	if _no_ground_ahead(_move_dir):
		_move_dir = 0


func _move(delta: float) -> void:
	# 重力：和 Player.gd 用同一个常数，保证手感和落地时机一致
	if not is_on_floor():
		velocity.y = minf(velocity.y + gravity * delta, max_fall_speed)
	elif velocity.y > 0.0:
		velocity.y = 0.0

	var speed := chase_speed if _state == State.CHASE else patrol_speed
	velocity.x = float(_move_dir) * speed

	move_and_slide()
	_sync_visual()

	# 撞墙 -> 巡逻中掉头（is_on_wall() 只有在"刚被墙挡住"时才为 true，所以放在移动之后判断）
	if _state == State.PATROL and _move_dir != 0 and is_on_wall():
		_start_turn()


# ────────────────────────────── 地面 / 视线检测 ──────────────────────────────

## 指定方向的前方脚下有没有地面。
## 用 force_raycast_update() 强制立刻刷新：射线默认只在物理帧的固定时机更新，
## 移动中直接读 is_colliding() 可能拿到上一帧的位置结果，边界上会差一两像素。
func _no_ground_ahead(dir: int) -> bool:
	if _ledge_probe == null:
		return false
	_ledge_probe.position.x = _probe_forward * float(dir)
	_ledge_probe.force_raycast_update()
	return not _ledge_probe.is_colliding()


## 玩家检测：一条朝向正前方的射线。
## 第一命中是"玩家"= 看得见；第一命中是"墙"= 被挡住了（隔墙发现是 Area2D 方案的常见 bug）。
func _update_sight(delta: float) -> void:
	if not can_chase or _sight == null:
		return

	_sight.target_position = Vector2(sight_distance * float(_facing), 0.0)
	_sight.force_raycast_update()

	var seen_now := false
	if _sight.is_colliding():
		var hit := _sight.get_collider()
		if hit is Node2D and _is_in_group_upwards(hit, GROUP_PLAYER):
			_seen_player = hit as Node2D
			seen_now = true

	if seen_now:
		_lost_timer = lose_sight_time
		if _state != State.CHASE:
			_state = State.CHASE
			_turn_timer = 0.0
	elif _state == State.CHASE:
		_lost_timer -= delta
		if _lost_timer <= 0.0:
			_end_chase()


func _end_chase() -> void:
	_seen_player = null
	_lost_timer = 0.0
	_state = State.TURN_PAUSE   # 追丢后先愣一下再回到巡逻，顺便掉头
	_turn_timer = turn_pause
	_facing = -_facing
	_move_dir = 0


## 切换巡逻方向（带停顿 + 窄柱子保护）
func _start_turn() -> void:
	_facing = -_facing
	_move_dir = 0
	_turn_timer = turn_pause
	_state = State.TURN_PAUSE
	_sync_visual()

	# 新方向前方也没地面 -> 站住（否则会在两根崖边之间来回抽筋）
	if _no_ground_ahead(_facing):
		_state = State.IDLE


## 视觉朝向翻转
##
## ⚠️ 以前这里写的是 `_visual.scale.x = float(_facing)` —— 那是给对称色块用的。
##    换成 Sprite2D 后**必须改成 flip_h**，否则会把 scale 从 (2,2) 覆盖成 (-1,2)：
##    不只是翻转，还会把精灵在水平方向压扁成一半大小。
##    这里做类型判断，兼容 ColorRect（色块）和 Sprite2D（精灵图）两种视觉节点。
func _sync_visual() -> void:
	if _visual == null:
		return
	if _visual is Sprite2D:
		(_visual as Sprite2D).flip_h = _facing < 0
	else:
		_visual.scale.x = float(_facing)


# ────────────────────────────── 一击必杀 ──────────────────────────────

## 被玩家的攻击框罩住时调用（Player.gd 会向上找 "enemy" 组的祖先，所以这里就是根节点）
func kill() -> void:
	if _dead:
		return
	_dead = true

	# ⚠️ 移动敌人必做：立刻停止移动，否则"尸体"会带着速度继续滑行/掉出屏幕
	velocity = Vector2.ZERO
	_move_dir = 0
	set_physics_process(false)

	if _danger:
		_danger.set_deferred("monitoring", false)
	if _shape:
		_shape.set_deferred("disabled", true)

	# 闪一下再"消失"
	#
	# ⚠️ 这里**不能 queue_free()**：一旦从场景移除，Main.gd 的
	#    get_nodes_in_group("enemy") 就再也找不到它，reset_enemy() 无从调用，
	#    "检查点之后的敌人复活"整条链路直接废掉。
	#    所以改成"隐藏 + 关碰撞"，节点留在树上等复位。
	var tw := create_tween()
	if _visual:
		tw.tween_property(_visual, "modulate", Color(1.6, 1.2, 0.4, 1.0), 0.06)
		tw.tween_property(_visual, "modulate:a", 0.0, 0.12)
	tw.tween_callback(_hide_on_death)

	died.emit()


## 死亡后隐藏（而不是删除），保留节点和组标记以便 reset_enemy() 复活
##
## ⚠️ 这里**不能 remove_from_group**：Main.gd 靠 get_nodes_in_group("enemy")
##    找到敌人来做复位，一旦退组就再也找不到了。
##    组标记代表"这是一个敌人"，死活状态由 _dead 表示。
func _hide_on_death() -> void:
	if _visual:
		_visual.visible = false
	set_physics_process(false)


func _on_danger_body_entered(body: Node2D) -> void:
	# 保留信号路径：敌人不动时它是唯一入口；配合轮询时它只是"早一帧"的补充。
	# 延迟一帧再判死：让同一帧内"玩家先砍中"优先成立，
	# 避免"我砍中它了但同时也被它撞死"这种不公平的同归于尽。
	if _kill_pending:
		return
	_kill_pending = true
	_kill_player_deferred.call_deferred(body)


func _kill_player_deferred(body: Node2D) -> void:
	_kill_pending = false
	if _dead:
		return
	if not is_instance_valid(body):
		return
	var root := _find_group_ancestor(body, GROUP_PLAYER)
	if root and root.has_method("die"):
		root.die()


## 开关危险区。关卡在"玩家刚复活"时应该短暂关掉它：
## 否则检查点一旦被巡逻兵占住（或它正好走过来），玩家会陷入连环死亡。
## 用 set_deferred 是必须的 —— 直接改 monitoring 若发生在物理查询期间会被引擎拒绝。
func set_danger_enabled(on: bool) -> void:
	if _danger == null or not is_instance_valid(_danger):
		return
	_danger.set_deferred("monitoring", on)
	if on:
		_kill_pending = false   # 重新打开时允许立刻重新判死


## 沿父节点链向上找第一个属于指定组的节点（含自身）。
## 这个"坑 1"在 README 里写过：组不会传递给子节点，碰撞回调给的是碰撞体本身。
func _find_group_ancestor(node: Node, group: String) -> Node:
	var cur: Node = node
	while cur != null:
		if cur.is_in_group(group):
			return cur
		cur = cur.get_parent()
	return null


func _is_in_group_upwards(node: Node, group: String) -> bool:
	return _find_group_ancestor(node, group) != null


# ────────────────────────────── 给关卡用的接口 ──────────────────────────────

## 把敌人放回出生点并清空状态。
## 建议在 Main.gd 的 respawn 流程里调用 —— 否则敌人可能正好站在检查点上，
## 玩家一复活就被撞死，出现"无限死亡循环"。
## 复活/复位：由 Main.gd 在玩家死亡后对"检查点之后"的敌人调用
##
## ⚠️ 原实现开头是 `if _dead: return`——**已死的敌人不会被复位**。
##    那对"永久死亡"合理，但和"快重开"冲突：玩家死一次后那一屏就少一个敌人，
##    难度会随死亡次数漂移。现在改成默认连已死的也复活，
##    让每次重开都是同样的初始状态（要保留永久死亡就传 false）。
func reset_enemy(revive_dead: bool = true) -> void:
	global_position = _spawn_position
	if _dead and not revive_dead:
		return

	if _dead:
		# 复活：把 kill() 里关掉的东西都打开
		# 注意不需要重新 add_to_group —— 组标记从不移除，它代表"这是个敌人"，
		# 死活状态由 _dead 表示。
		_dead = false
		set_physics_process(true)
		if _danger:
			_danger.set_deferred("monitoring", true)
		if _visual:
			_visual.modulate = Color(1, 1, 1, 1)
			_visual.visible = true
		if _shape:
			_shape.set_deferred("disabled", false)

	velocity = Vector2.ZERO
	_facing = 1
	_move_dir = 1
	_state = State.PATROL
	_lost_timer = 0.0
	_seen_player = null
	_kill_pending = false
	_sync_visual()


func is_dead() -> bool:
	return _dead


func get_state_name() -> String:
	return State.keys()[_state]


# ────────────────────────────── 调试可视化 ──────────────────────────────

func _draw() -> void:
	var half := _body_size * 0.5
	# 巡逻区间（相对自身画，所以会随移动"滑动"，但足够看出边界在哪）
	var y := -half.y - 8.0
	var lx := _left_x - global_position.x
	var rx := _right_x - global_position.x
	draw_line(Vector2(lx, y), Vector2(rx, y), Color(1, 1, 1, 0.25), 1.0)
	draw_line(Vector2(lx, y - 4.0), Vector2(lx, y + 4.0), Color(1, 1, 1, 0.4), 1.0)
	draw_line(Vector2(rx, y - 4.0), Vector2(rx, y + 4.0), Color(1, 1, 1, 0.4), 1.0)

	# 朝向标记（Rect2 的 size 必须是正数，所以按朝向算左上角）
	var col := Color(0.35, 1.0, 0.5, 0.8) if _state == State.CHASE else Color(1, 0.6, 0.3, 0.7)
	var mark_x := half.x if _facing > 0 else -half.x - 6.0
	draw_rect(Rect2(Vector2(mark_x, -3.0), Vector2(6.0, 6.0)), col, true)
