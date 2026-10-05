extends Node2D
## 精英敌人 —— 需要砍 4 刀的敌人（第一版）
##
## 为什么要有它：
##   一击必杀的杂兵**体现不出元素的价值** —— 砍谁都死，那火/冰/雷有什么区别？
##   精英怪用血量把战斗拉长，"元素弱点 / 元素护盾"才有容身之处。
##   （用户 2026-10-05 拍板的"分层"方案：杂兵一击必杀 / 精英有血 + 元素弱点 / Boss 以后再说）
##
## 结构完全复用 Enemy.gd：
##   Node2D(本脚本) + Body(StaticBody2D, 第 4 层) + Danger(Area2D, 检测玩家第 2 层)
## 差别只有两点：
##   1. 被砍中不会立刻死，而是 hp -= 1，并给出受击反馈（闪白 + 短促放大回弹）
##   2. hp 归零才走死亡流程；检查点复位时**满血**复活
##
## ⚠️ 和杂兵一样：死亡**绝不能 queue_free()**。
##    一旦从场景移除，Main.gd 的 get_nodes_in_group("enemy") 就找不到它，
##    reset_enemy() 无从调用 —— "检查点之后的敌人复位"整条链路直接废掉。
##    所以是"隐藏 + 关碰撞"，节点留在树上等复位。
##
## ⚠️ 死亡后**也不退组**：组标记代表"这是个敌人"，死活由 _dead / hp 表示。
##    测试要数活敌必须问 is_dead()，不能看组的大小。

signal died                     ## 血量归零时发出（Main.gd 靠它计分）
signal damaged(remaining: int)  ## 每次受击发出（将来接音效 / 飘字 / HUD 血条）
signal aura_changed(element: String, remaining: float)  ## 元素附着变化（附着/刷新/消失都发）

## 第一版精英 4 滴血（用户 2026-10-06 定）。
## 为什么是 4：杂兵是 1 刀，4 刀刚好长到"需要认真对待"，
## 又没长到变成站桩互砍 —— 武士刀零的节奏里超过 5 刀就开始腻。
const MAX_HP := 4

## 元素附着持续时间（用户 2026-10-06 定）：2 秒。
## 2 秒内再次被同元素打中 → 计时**重置**（而不是叠加、也不是延长到超过 2 秒）。
## 这是元素反应的前置条件：先让敌人身上"带着火"，将来水打上去才有蒸发可算。
const AURA_DURATION := 2.0

## 受击闪白：用大于 1 的分量，让精灵在偏暗背景上"炸"一下（modulate 允许超 1）
const HIT_FLASH := Color(2.2, 2.2, 2.2, 1.0)
const HIT_FLASH_TIME := 0.07     ## 闪白时长
const HIT_PUNCH_SCALE := 0.22    ## 受击瞬间放大比例（"打得动"的手感）
const HIT_PUNCH_BACK := 0.09     ## 回弹时间

## 附着状态下敌人身上的颜色（火 = 偏红）。
## 做成"底色"而不是直接 tween 到它，是为了和受击闪白共存：
## 闪白结束后要回到**附着色**，而不是回到白色。
const AURA_COLORS := {
	"fire": Color(1.55, 0.72, 0.55, 1.0),
}
const AURA_DEFAULT_COLOR := Color(1.25, 1.05, 0.95, 1.0)   ## 未登记元素的兜底色
const TINT_CLEAR := Color(1, 1, 1, 1)

## 头顶附着图标的闪烁周期（单程时长，一次亮灭 = 2 倍）
const AURA_BLINK_TIME := 0.26
## 图标贴图目录。文件名 = 元素名（fire.png / water.png …），由
## tools/gen_element_icons.py 生成，见 art/elements/。
const AURA_ICON_DIR := "res://art/elements/"

var hp := MAX_HP
var _dead := false
var _spawn_position := Vector2.ZERO
var _base_scale := Vector2.ONE
var _hit_tween: Tween = null

## 元素附着状态。_aura_element 为空串表示当前没有附着。
## ⚠️ 第一版只允许**一种**附着：新元素直接覆盖旧的（不做"多元素共存"）。
##    原因：多附着会立刻把复杂度拉到"谁和谁反应、顺序如何"，而这一步只需要
##    "身上有没有火"，够用就行。
var _aura_element := ""
var _aura_left := 0.0

## 用 get_node_or_null 而不是 @onready：
## 这样即使子节点还没挂好，也只是功能缺失，而不是抛 null 异常把整个脚本打断。
var danger: Area2D
var body_shape: CollisionShape2D
var visual: CanvasItem
var aura_icon: Sprite2D
var _aura_tween: Tween = null


func _ready() -> void:
	danger = get_node_or_null("Danger") as Area2D
	body_shape = get_node_or_null("Body/Shape") as CollisionShape2D
	visual = get_node_or_null("Body/Visual") as CanvasItem
	aura_icon = get_node_or_null("AuraIcon") as Sprite2D
	_spawn_position = global_position
	if visual:
		_base_scale = visual.scale

	add_to_group("enemy")
	add_to_group("elite")      # 单独标记：关卡逻辑和测试可以只找精英
	hp = MAX_HP

	if danger:
		danger.body_entered.connect(_on_danger_body_entered)


## 被玩家的攻击判定框罩住时调用（Player.gd 会向上找 "enemy" 组的祖先，所以这里就是根节点）
##
## `_element` 现在只收不用；等做元素反应（蒸发 / 融化 / 超载…）时，
## 就在这里判断"这一刀的元素是不是它的弱点 / 能不能破它的盾"。
## 签名带默认值是为了兼容无参调用（测试和生成器都会这么调）。
func kill(element: String = "") -> void:
	if _dead:
		return

	# 先处理元素附着：只要这一刀带元素就先挂上，与"这一刀是否打死它"无关。
	# 打死的那一刀也照样附着 —— 否则"最后一击用什么元素"就看不出区别了。
	if element != "":
		_apply_aura(element)

	hp -= 1
	damaged.emit(hp)

	if hp > 0:
		_play_hit_reaction()
		return

	_die()


## 挂上 / 刷新元素附着
##
## 用户 2026-10-06 的规则：持续 2 秒；2 秒内**再次被同元素打中则计时重置**。
## 注意是"重置回 2 秒"而不是"累加" —— 否则连续攻击会把附着时间堆到离谱，
## 将来做反应时会变成"永远挂着火"。
func _apply_aura(element: String) -> void:
	_aura_element = element
	_aura_left = AURA_DURATION
	_refresh_aura_tint()
	_show_aura_icon(element)
	aura_changed.emit(_aura_element, _aura_left)


## 头顶显示该元素的图标并让它闪烁
##
## 用户 2026-10-06：被附着的角色头顶闪烁元素图标（变色保留）。
## 造型是自家生成的几何像素符号，不是官方素材（见 tools/gen_element_icons.py）。
##
## ⚠️ 容错：贴图缺失时**不要崩**，只是没图标 —— 新增元素时很容易忘记生成图标，
##    那种情况下"附着照常工作、只是看不见"才是可接受的行为。
func _show_aura_icon(element: String) -> void:
	_stop_aura_blink()
	if aura_icon == null:
		return

	var tex_path := AURA_ICON_DIR + element + ".png"
	if not ResourceLoader.exists(tex_path):
		aura_icon.visible = false
		return

	aura_icon.texture = load(tex_path)
	aura_icon.visible = true
	aura_icon.modulate = Color(1, 1, 1, 1)

	# 循环亮灭。用独立 tween 而不是 tween_callback 递归，停止时 kill 干净。
	_aura_tween = create_tween().set_loops()
	_aura_tween.tween_property(aura_icon, "modulate:a", 0.30, AURA_BLINK_TIME)
	_aura_tween.tween_property(aura_icon, "modulate:a", 1.00, AURA_BLINK_TIME)


func _stop_aura_blink() -> void:
	if _aura_tween != null and _aura_tween.is_valid():
		_aura_tween.kill()
	_aura_tween = null
	if aura_icon != null:
		aura_icon.visible = false
		aura_icon.modulate = Color(1, 1, 1, 1)


## 附着倒计时
##
## 用 _physics_process 而不是 _process：物理帧率固定 60Hz，计时更稳；
## 而且它同样受 Engine.time_scale 影响 —— 子弹时间下附着也跟着变慢，这是对的
## （世界整体放慢，不该只有玩家这边的状态在正常走）。
func _physics_process(delta: float) -> void:
	if _aura_element == "":
		return
	_aura_left -= delta
	if _aura_left <= 0.0:
		_clear_aura()


func _clear_aura() -> void:
	_aura_element = ""
	_aura_left = 0.0
	_refresh_aura_tint()
	_stop_aura_blink()
	aura_changed.emit("", 0.0)


## 当前附着状态下的"底色"
##
## 抽出来是因为受击闪白（tween）结束后必须回到**这个**颜色，
## 而不是硬编码回白色 —— 否则一挨打，火附着的视觉就没了。
func _base_modulate() -> Color:
	if _aura_element == "":
		return TINT_CLEAR
	return AURA_COLORS.get(_aura_element, AURA_DEFAULT_COLOR)


## 把底色刷到精灵上（有受击 tween 在跑时先不动，它结束时会自己回到新底色）
func _refresh_aura_tint() -> void:
	if visual == null:
		return
	if _hit_tween != null and _hit_tween.is_valid():
		return
	visual.modulate = _base_modulate()


## 受击反馈：闪白 + 短促放大回弹
##
## 为什么必须有：4 刀砍下去如果毫无反馈，玩家根本不知道这一刀打中没有 ——
## 对"一击必杀"习惯了的玩家来说，那种"砍了没反应"的体验极像卡了 bug。
func _play_hit_reaction() -> void:
	if visual == null:
		return

	# 先掐掉上一段受击动画：攻击冷却只有 0.26 秒，而这段动画约 0.16 秒，
	# 连砍时两段会重叠，掐掉才不会让 scale 越叠越大、最后回不了位。
	if _hit_tween != null and _hit_tween.is_valid():
		_hit_tween.kill()
	visual.scale = _base_scale

	_hit_tween = create_tween()
	_hit_tween.tween_property(visual, "modulate", HIT_FLASH, HIT_FLASH_TIME)
	_hit_tween.parallel().tween_property(visual, "scale", _base_scale * (1.0 + HIT_PUNCH_SCALE), HIT_FLASH_TIME)
	# 回到**当前底色**（有附着就是火色），而不是硬编码回白色 ——
	# 否则每挨一刀，火附着的视觉就会闪回白色再变红，看着像掉状态。
	_hit_tween.tween_property(visual, "modulate", _base_modulate(), HIT_PUNCH_BACK)
	_hit_tween.parallel().tween_property(visual, "scale", _base_scale, HIT_PUNCH_BACK)


## 血量归零：走和普通敌人一样的"隐藏 + 关碰撞"流程
func _die() -> void:
	_dead = true

	if _hit_tween != null and _hit_tween.is_valid():
		_hit_tween.kill()

	if danger:
		danger.set_deferred("monitoring", false)
	if body_shape:
		body_shape.set_deferred("disabled", true)

	if visual:
		var tw := create_tween()
		tw.tween_property(visual, "modulate", Color(1.8, 0.9, 0.3, 1.0), 0.10)
		tw.tween_property(visual, "modulate:a", 0.0, 0.16)
		tw.tween_callback(_hide_on_death)
	else:
		_hide_on_death()

	died.emit()


func _hide_on_death() -> void:
	if visual:
		visual.visible = false


## 复位：回到出生点并**满血**（检查点复活时由 Main.gd 调用）
##
## revive_dead = true 时连已死的也复活 —— 保证每次重开都是同样的初始状态，
## 否则"死一次少一个敌人"，关卡难度会随重开次数漂移。
func reset_enemy(revive_dead: bool = true) -> void:
	global_position = _spawn_position
	if _dead and not revive_dead:
		return

	hp = MAX_HP
	_dead = false

	# 复位时元素附着一并清掉：否则"死一次复活回来身上还带着火"，
	# 等元素反应做进来之后会变成很难复现的脏状态。
	_aura_element = ""
	_aura_left = 0.0
	_stop_aura_blink()

	if _hit_tween != null and _hit_tween.is_valid():
		_hit_tween.kill()

	if danger:
		danger.set_deferred("monitoring", true)
	if body_shape:
		body_shape.set_deferred("disabled", false)
	if visual:
		# 必须把受击/死亡 tween 留下的痕迹清干净，
		# 否则会以"半透明 + 被放大"的姿态复活。
		visual.modulate = TINT_CLEAR
		visual.scale = _base_scale
		visual.visible = true


func _on_danger_body_entered(body: Node2D) -> void:
	# 和杂兵一致：延迟一帧再判死，让同帧内的玩家攻击优先成立，
	# 避免"我砍中它、但同时被它撞死"。
	_kill_player_deferred.call_deferred(body)


## 供测试 / 关卡逻辑查询死活
## ⚠️ 死了也不退组，所以"它死了吗"必须问这个方法。
func is_dead() -> bool:
	return _dead


## 供测试 / HUD 查询剩余血量
func get_hp() -> int:
	return hp


## 当前附着的元素（"" = 没有附着）
func get_aura() -> String:
	return _aura_element


## 附着是否还在（将来元素反应的第一道判断）
func has_aura() -> bool:
	return _aura_element != ""


## 附着剩余秒数 —— 供测试断言"重置"行为用
func get_aura_left() -> float:
	return _aura_left


## 头顶图标节点（供测试断言"看得见"）
func get_aura_icon() -> Sprite2D:
	return aura_icon


func _kill_player_deferred(body: Node2D) -> void:
	if _dead:
		return
	# 同样要向上找组：碰撞体未必就是挂了脚本的那个节点
	var root := _find_group_ancestor(body, "player")
	if root and root.has_method("die"):
		root.die()


func _find_group_ancestor(node: Node, group: String) -> Node:
	var cur: Node = node
	while cur != null:
		if cur.is_in_group(group):
			return cur
		cur = cur.get_parent()
	return null
