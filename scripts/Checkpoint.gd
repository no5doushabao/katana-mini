extends Area2D
## 检查点区域 —— 玩家走过就更新复活点
##
## 为什么需要它（这次不是"锦上添花"，是前置阻塞项）：
##   `Main.gd` 原来只在 `_ready()` 里存一次出生点、之后**无处更新**，
##   所以"死亡 0.45 秒回检查点"实际是"永远回出生点"。
##   多屏关卡下这意味着每次死都要重跑一大段空路——
##   而**快重开的全部价值就在于"复活点贴着难点"**。
##
## 用法：把这个 Area2D 放在每一屏的入口处（检测玩家层 = 第 2 层）。

@export var one_shot := false       ## true = 只触发一次（默认允许多次，便于回头）
@export var show_visual := true     ## 是否显示视觉标记

var _triggered := false
var _visual: Node2D


func _ready() -> void:
	collision_layer = 0
	collision_mask = 2              # 只检测玩家层
	monitoring = true
	add_to_group("checkpoint")

	_visual = get_node_or_null("Visual")
	body_entered.connect(_on_body_entered)


func _on_body_entered(body: Node2D) -> void:
	if one_shot and _triggered:
		return

	# 向上找 level 节点（碰撞体未必就是挂了脚本的那个节点）
	var lvl := get_tree().get_first_node_in_group("level")
	if lvl and lvl.has_method("set_checkpoint"):
		# 用自身的 x、但保留玩家的 y —— 复活点应该在"地面上"而不是悬空
		var spawn := Vector2(global_position.x, body.global_position.y)
		lvl.set_checkpoint(spawn)
		_triggered = true
		if _visual and _visual.has_method("flash"):
			_visual.flash()


## 供测试/调试：查询是否已触发
func is_triggered() -> bool:
	return _triggered
