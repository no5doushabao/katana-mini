extends Node2D
## 敌人 —— 第一版只做"站着不动的靶子"
##
## 为什么第一版不做敌人 AI？
##   因为《武士刀零》的乐趣不在"敌人会追你"，而在"你得在正确时机出手"。
##   先有稳定的靶子，才能调出攻击判定和节奏；AI 移动会让调参时充满随机性。
##
## 一击必杀是双向的：
##   - 玩家的攻击框罩住敌人主体（Body，第 3 层）-> kill()
##   - 敌人的危险区（Danger，检测玩家的第 2 层）罩住玩家 -> 玩家死
##
## 谁先判定？Danger 用 call_deferred 延迟一帧，
## 让同一帧内的"玩家攻击"优先成立，避免"我砍中它但同时被它撞死"。

signal died

var _dead := false

var danger: Area2D
var body_shape: CollisionShape2D
# 用 CanvasItem 而不是 ColorRect：
# 换精灵图后 Visual 变成了 Sprite2D，写死 ColorRect 会导致类型转换失败变成 null，
# 于是"死亡闪烁"整个失效（而且不报错，很难发现）。ColorRect 和 Sprite2D 都有 modulate。
var visual: CanvasItem
var _spawn_position := Vector2.ZERO

## 碰到玩家造成的伤害（对应 Player 的 HURT_SMALL 档）
const HURT_DAMAGE := 1

## true = 每物理帧轮询危险区（推荐）；false = 只依赖 body_entered 信号。
## ⭐ 2026-10-08：默认改 true —— body_entered 只在"重叠从无到有"那一帧发一次，
##    玩家在敌人身上复活时信号不再发，会拿到"隐形无敌"（§2.6 记的老 bug）。
##    这个修法是从 PatrolEnemy._poll_danger() 抄的（那边早就修了，这边漏了）。
@export var danger_polling := true


func _ready() -> void:
	# 用 get_node_or_null 而不是 @onready：
	# 这样即使子节点还没挂好也只是功能缺失，而不是抛 null 异常把整个脚本打断。
	danger = get_node_or_null("Danger") as Area2D
	body_shape = get_node_or_null("Body/Shape") as CollisionShape2D
	visual = get_node_or_null("Body/Visual") as CanvasItem
	_spawn_position = global_position

	add_to_group("enemy")

	if danger:
		danger.body_entered.connect(_on_danger_body_entered)


## 每物理帧检查危险区里的玩家 —— **兜底判伤**。
##
## 和 body_entered 是双保险：body_entered 管"刚接触那一帧"立刻响应，
## 轮询管"一直重叠着"（复活在敌人身上、被推回来）。
## 两者可能同帧都触发 → 由玩家侧的无敌帧去重，不会重复扣血。
func _physics_process(_delta: float) -> void:
	if _dead or not danger_polling:
		return
	if danger == null or not is_instance_valid(danger) or not danger.monitoring:
		return
	for body in danger.get_overlapping_bodies():
		if body is Node2D and _find_group_ancestor(body, "player") != null:
			_hit_player_deferred.call_deferred(body)
			return


## 复活/复位：由 Main.gd 在玩家死亡后对"检查点之后"的敌人调用
##
## ⚠️ 注意和 PatrolEnemy.gd 的差别：那份实现开头是 `if _dead: return`，
##    也就是**已经死掉的敌人不会被复位**。那对"永久死亡"是合理的，
##    但和"快重开"冲突——玩家死一次之后，那一屏的敌人就少一个，难度会漂移。
##    这里做成 **true = 连已死的也复活**，让每次重开都是同样的初始状态。
func reset_enemy(revive_dead: bool = true) -> void:
	global_position = _spawn_position
	if _dead and not revive_dead:
		return

	if _dead:
		# 复活：把 kill() 里关掉的东西都打开
		# 注意不需要重新 add_to_group —— 组标记从不移除，它代表"这是个敌人"，
		# 死活状态由 _dead 表示。
		_dead = false
		if danger:
			danger.set_deferred("monitoring", true)
		if body_shape:
			body_shape.set_deferred("disabled", false)
		if visual:
			visual.modulate = Color(1, 1, 1, 1)
			visual.visible = true


## 被玩家攻击判定框覆盖时调用
##
## `_element` 是为「元素系统」预留的：玩家攻击时会带上当前附魔元素
## （见 Player.gd 的 _on_attack_hit）。普通杂兵**故意忽略**它 ——
## 一击必杀是武士刀零的爽感来源，不该被元素改变（用户拍板的"分层"方案：
## 杂兵一击必杀 / 精英有血 + 元素弱点）。
## 默认值是为了兼容无参调用（测试与生成器都这么调）。
func kill(_element: String = "") -> void:
	if _dead:
		return
	_dead = true

	if danger:
		danger.set_deferred("monitoring", false)
	if body_shape:
		body_shape.set_deferred("disabled", true)

	# 死亡表现：闪一下再"消失"
	#
	# ⚠️ 这里**不能 queue_free()**：一旦从场景移除，
	#    Main.gd 的 get_nodes_in_group("enemy") 就找不到它，
	#    reset_enemy() 无从调用 —— "检查点之后的敌人复活"整条链路直接废掉。
	#    所以改成"隐藏 + 关碰撞"，节点留在树上等复位。
	if visual:
		var tw := create_tween()
		tw.tween_property(visual, "modulate", Color(1.6, 1.2, 0.4, 1.0), 0.06)
		tw.tween_property(visual, "modulate:a", 0.0, 0.12)
		tw.tween_callback(_hide_on_death)
	else:
		_hide_on_death()

	died.emit()


## 死亡后隐藏（而不是删除），保留节点和组标记以便 reset_enemy() 复活
func _hide_on_death() -> void:
	if visual:
		visual.visible = false


func _on_danger_body_entered(body: Node2D) -> void:
	# 延迟一帧再判伤，给同帧内的玩家攻击留出优先权
	_hit_player_deferred.call_deferred(body)


## 供测试/关卡逻辑查询死活状态
##
## 注意：敌人死后**不会从 "enemy" 组移除**（否则检查点复位就找不到它了），
## 所以"它死了吗"必须问这个方法，**不能靠 get_nodes_in_group("enemy").size() 判断**。
func is_dead() -> bool:
	return _dead


func _hit_player_deferred(body: Node2D) -> void:
	if _dead:
		return
	# 同样要向上找组：碰撞体未必就是挂了脚本的那个节点
	var root := _find_group_ancestor(body, "player")
	if root == null:
		return
	# 优先走血量系统（take_damage）；die() 只作兜底（万一对象没有血量接口）
	if root.has_method("take_damage"):
		root.take_damage(HURT_DAMAGE)
	elif root.has_method("die"):
		root.die()


func _find_group_ancestor(node: Node, group: String) -> Node:
	var cur: Node = node
	while cur != null:
		if cur.is_in_group(group):
			return cur
		cur = cur.get_parent()
	return null
