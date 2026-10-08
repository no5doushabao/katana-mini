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

## 掉到这个 y 以下 = 判定死亡（用户 2026-10-07）。
##
## 为什么必须有：地图的沟是**无底洞**，没有这条判定的话玩家掉下去会**永远坠落** ——
## 死不了、也回不来，只能自己按 R。那不是"不够合理"，是**卡死状态**；
## 而且它顺手废掉了关卡设计：屏 2 那条 110px 深沟（"冲刺要收得住"的教学）会变成纯装饰。
##
## ⭐ 阈值取 620 的用意：地面顶部在 480、屏幕高 540 ——
##    也就是**掉出画面之后**才判死。正常跳跃（约 65px 高）和落回平台绝不会被误伤。
const FALL_DEATH_Y := 620.0

## 操作提示文案（放在代码里 —— 改文案不用重跑生成器）
const HELP_TEXT := "← → 移动   空格 跳   K 冲刺   J 攻击   L 切换元素   Shift 子弹时间   R 重开"

## 元素图标目录：**文件名 = 元素名**（§2.13 的约定 —— 以后加冰/雷/草只要生成同名 PNG，
## 这里一行都不用改）
const ELEMENT_ICON_DIR := "res://art/elements/"

var checkpoint: Vector2 = Vector2.ZERO
var lives := 0                ## 死亡次数（顺手统计，调难度时有用）
var kills := 0                ## 击杀数

@onready var player: CharacterBody2D = $Player
@onready var hud: Label = $HUD/Info            ## 左上：击杀 / 死亡 / 当前元素（+ 精英血量）
## 下面三个用 get_node_or_null：节点万一没生成出来，只是"少一行显示"，
## 而不是抛 null 异常把整个关卡打断（Enemy.gd 里同样的理由）。
@onready var hp_bar: Label = get_node_or_null("HUD/HpBar") as Label        ## 左上：玩家血条
@onready var slow_bar: Label = get_node_or_null("HUD/SlowBar") as Label    ## 左上：子弹时间能量
@onready var help_text: Label = get_node_or_null("HUD/HelpText") as Label  ## 底部：操作提示
@onready var elem_icon: TextureRect = get_node_or_null("HUD/ElemIcon") as TextureRect  ## 右上：当前元素图标

var _respawn_timer := -1.0


func _ready() -> void:
	add_to_group("level")
	checkpoint = player.global_position

	# 把所有敌人的"死亡"接到计分上
	for e in get_tree().get_nodes_in_group("enemy"):
		e.died.connect(_on_enemy_died)

	# 精英 / 木桩每次受击都刷新 HUD —— 否则血条只在击杀、死亡时才更新，
	# 打木桩的过程中数字根本不动，那这个血条就白加了。
	for e in get_tree().get_nodes_in_group("elite"):
		if e.has_signal("damaged"):
			e.damaged.connect(_on_elite_damaged)

	# 切换元素时刷新 HUD —— 否则"当前元素"这行字会一直停在开局那个值，
	# 玩家按了 L 却看不到任何文字反馈（月牙颜色只有攻击那一瞬才看得到）。
	if player and player.has_signal("element_changed"):
		player.element_changed.connect(_on_element_changed)

	# 血量变化 → 刷新血条。用信号而不是每帧刷：血条只在受击/复活时才变。
	if player and player.has_signal("hp_changed"):
		player.hp_changed.connect(_on_hp_changed)

	if help_text:
		help_text.text = HELP_TEXT

	_update_hud()
	_update_hp_bar()
	_update_element_icon()


func _on_element_changed(_element: String) -> void:
	_update_hud()
	_update_element_icon()


## 右上角方框里的**当前元素图标**（阿包 2026-10-09 睡前要的）。
##
## ⚠️ 贴图加载失败时 load() 返回 **null 而且不报错**（§8.1 老坑：新 PNG 没 --import
##    就会这样）—— 所以这里主动喊一声，否则表现只是"框里空着"，谁也不知道为什么。
func _update_element_icon() -> void:
	if elem_icon == null or player == null:
		return
	var elem: String = str(player.get("element"))
	if elem == "":
		return
	var tex := load(ELEMENT_ICON_DIR + elem + ".png") as Texture2D
	if tex == null:
		push_warning("元素图标缺失或没 import：%s%s.png" % [ELEMENT_ICON_DIR, elem])
		return
	elem_icon.texture = tex


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

	# ── 掉出世界底部 = **失去全部生命**（阈值依据见 FALL_DEATH_Y）──
	# 用 _is_dead 而不是 _respawn_timer 判重：人已经死了就别再判一次，
	# 否则整个坠落过程会每帧调一次（那边自己有守卫，但没必要）。
	if player and not player.get("_is_dead") and player.global_position.y > FALL_DEATH_Y:
		if player.has_method("take_fall_damage"):
			player.take_fall_damage()   # 全损 + 坠落的专用抖动档位
		else:
			player.die()

	if _respawn_timer > 0.0:
		_respawn_timer -= delta
		if _respawn_timer <= 0.0:
			# 先复位敌人，再放玩家——否则可能一复活就被"上一轮残留"撞死
			_reset_enemies_after(checkpoint)
			player.respawn(checkpoint)
			_update_hud()
			_update_hp_bar()


## 玩家血条：20 格方块，**一格 = 1 点血**（20 血正好一格一滴，读数最直观）
func _update_hp_bar() -> void:
	if hp_bar == null or player == null:
		return
	var cur: int = int(player.get("hp"))
	# ⚠️ 血量上限走 get_max_hp()，不用 player.get("MAX_HP")：
	#    get() 读的是"属性"，常量不保证读得到（别学 _update_slow_bar 里那种写法）。
	var cap: int = 20
	if player.has_method("get_max_hp"):
		cap = player.get_max_hp()
	if cap <= 0:
		return
	var filled := clampi(int(round(float(cur) / float(cap) * 20.0)), 0, 20)
	hp_bar.text = "生命 %s %d/%d" % [
		"█".repeat(filled) + "░".repeat(20 - filled), cur, cap]


func _on_hp_changed(_hp: int, _max_hp: int) -> void:
	_update_hp_bar()


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


## 左上 Info：状态行 +（有精英时）精英血量行。
##
## ⚠️ 操作提示**不在这里了** —— 它已搬到屏幕底部的 HelpText。
##    原来两行塞进同一个 Label，把 30px 的框撑爆，文字画出框外压到 SlowBar 上，
##    就是用户报的"子弹时间那行字重叠了"。
func _update_hud() -> void:
	if hud:
		var elem := "-"
		if player and player.has_method("get_element_label"):
			elem = player.get_element_label()
		hud.text = "击杀 %d    死亡 %d    【当前元素：%s】" % [kills, lives, elem]
		# 精英 / 木桩的血量。
		# 试元素反应时必须看得见血量变化 —— 尤其木桩是"打空就回满"，
		# 没有血条的话，那一轮打空在视觉上是完全看不出来的。
		var line := _elite_status_line()
		if line != "":
			hud.text += "\n" + line


## 拼一行"精英血量"给 HUD
##
## 木桩会标成「木桩」并附一句说明 —— 否则玩家看到血量在 4 和 1 之间反复跳、
## 却永远不死，第一反应是"这游戏有 bug"。
func _elite_status_line() -> String:
	var parts: Array[String] = []
	for e in get_tree().get_nodes_in_group("elite"):
		if not e.has_method("get_hp"):
			continue
		var tag := "木桩" if e.get("is_dummy") else "精英"
		var cap := 0
		if e.has_method("get_max_hp"):
			cap = e.get_max_hp()
		parts.append("%s %d/%d" % [tag, e.get_hp(), cap])
	if parts.is_empty():
		return ""
	return "【" + "   ".join(parts) + "】  （木桩血打空会回满，不会死）"


func _on_elite_damaged(_remaining: int) -> void:
	_update_hud()
