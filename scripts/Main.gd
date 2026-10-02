extends Node2D
## 关卡控制器 —— 负责"一击必杀 + 立刻重开"的节奏
##
## 《武士刀零》真正的精髓在这一行代码里体现：
##   死了不是"读条重开"，而是"啪一下回到检查点"。
##   重开成本必须接近 0，玩家才敢试错，游戏才有那个味道。
##
## 所以本脚本刻意不重新加载场景（reload 要一帧、会闪屏），
## 而是直接把人挪回检查点。代价是敌人不会复活——第一版无所谓，
## 等有多个敌人和检查点分支时再改成"只重置区域"。

const RESPAWN_DELAY := 0.45   ## 死亡后停顿多久再回检查点（太短会看不清自己怎么死的）

var checkpoint: Vector2 = Vector2.ZERO
var lives := 0                ## 死亡次数（顺手统计，调难度时有用）
var kills := 0                ## 击杀数

@onready var player: CharacterBody2D = $Player
@onready var hud: Label = $HUD/Info
@onready var slow_bar: Label = $HUD/SlowBar

var _respawn_timer := -1.0


func _ready() -> void:
	add_to_group("level")
	checkpoint = player.global_position

	# 把所有敌人的"死亡"接到计分上
	for e in get_tree().get_nodes_in_group("enemy"):
		e.died.connect(_on_enemy_died)

	_update_hud()


## 由检查点区域（Area2D）调用：更新复活点
##
## ⚠️ 这里曾经是个真 bug：checkpoint 只在 _ready() 里赋值一次、之后无处更新，
##    所以"回检查点"实际是"永远回出生点"。多屏关卡下这意味着每次死都要跑 20 秒空路——
##    而"快重开"的全部价值就在于**复活点贴着难点**。
func set_checkpoint(pos: Vector2) -> void:
	# 只允许向前推进（防止走回头路把检查点弄退）
	if pos.x > checkpoint.x:
		checkpoint = pos


## 复活时重置"检查点之后"的敌人
##
## 为什么要重置：不重置的话复活后关卡状态是脏的——
## 你已经砍掉的敌人不会回来，但没砍的还在，多屏关卡无法重试。
## 只重置 x 在检查点之后的敌人：**身后的敌人不该复活**（否则玩家没法回头）。
func _reset_enemies_after(pos: Vector2) -> void:
	for e in get_tree().get_nodes_in_group("enemy"):
		if not is_instance_valid(e):
			continue
		if not (e is Node2D):
			continue
		if (e as Node2D).global_position.x >= pos.x:
			if e.has_method("reset_enemy"):
				e.reset_enemy()


func _process(delta: float) -> void:
	# 子弹时间能量条（每帧刷新，玩家脚本会读取它）
	_update_slow_bar()

	if Input.is_action_just_pressed("restart"):
		_restart_level()
		return

	if _respawn_timer > 0.0:
		_respawn_timer -= delta
		if _respawn_timer <= 0.0:
			# 先复位敌人，再放玩家——否则可能一复活就被"上一轮残留"撞死
			_reset_enemies_after(checkpoint)
			player.respawn(checkpoint)
			_update_hud()


## 用方块字符画一根能量条。纯文字，不用额外素材
func _update_slow_bar() -> void:
	if not slow_bar or not player:
		return
	var pct: float = player.get("_slow_energy") / player.get("SLOW_ENERGY_MAX")
	pct = clampf(pct, 0.0, 1.0)
	var filled := int(round(pct * 20.0))
	var bar := "█".repeat(filled) + "░".repeat(20 - filled)
	slow_bar.text = "子弹时间(按住 Shift)  %s  %d%%" % [bar, int(pct * 100.0)]


## 由 Player.die() 通过 "level" 组调用
func on_player_died() -> void:
	lives += 1
	_respawn_timer = RESPAWN_DELAY
	_update_hud()


func _on_enemy_died() -> void:
	kills += 1
	_update_hud()


func _restart_level() -> void:
	# 按 R 完全重开：敌人也复活，用来重新测试整关
	get_tree().reload_current_scene()


func _update_hud() -> void:
	if hud:
		hud.text = "击杀 %d    死亡 %d\n← → 移动   空格 跳   K 冲刺   J 攻击   Shift 子弹时间   R 重开" % [kills, lives]
