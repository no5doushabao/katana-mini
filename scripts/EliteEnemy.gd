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
signal reacted(kind: String, damage: int)               ## 发生元素反应（供 HUD / 特效 / 音效）

## 第一版精英 4 滴血（用户 2026-10-06 定）。
## 为什么是 4：杂兵是 1 刀，4 刀刚好长到"需要认真对待"，
## 又没长到变成站桩互砍 —— 武士刀零的节奏里超过 5 刀就开始腻。
const MAX_HP := 4

## 元素附着持续时间（用户 2026-10-06 定 2 秒 → 10-07 试玩后改成 3 秒）。
## 期间再次被同元素打中 → 计时**重置**（不是叠加、也不是延长到超过上限）。
## 这是元素反应的前置条件：先让敌人身上"带着火"，水打上去才有蒸发可算。
##
## 3 秒的理由：用户实测 2 秒太短 —— 后半段要完成"看到警告 → 切元素 → 攻击"
## 这套动作，2 秒的余量不够从容。
const AURA_DURATION := 3.0

## 剩余时间掉到这个值以下，头顶图标开始**闪烁**（之前是常亮）。
##
## 用户 10-07 的设计：把"剩余时间"编码进"闪不闪"里 ——
##   前段常亮 = 时间还久，不用急；
##   后段闪烁 = 快没了，该出手了。
## 于是玩家不用看任何数字，余光就能判断现在急不急。
##
## ⭐ 而且因为附着打中会**重置**，只要你还在用同元素连续砍，
##    _aura_left 就一直 > 这个阈值 → 图标永远不闪。
##    也就是：**不闪 = 你还在掌控节奏；开始闪 = 你停手了，附着正在溜走。**
const AURA_BLINK_AT := 1.5

# ── 元素反应的视觉：两个图标相撞（用户 10-07 的方案 B）──
#
# 为什么选"碰撞"而不是"并排显示"：
#   并排只表达"两个元素**共存**"，碰撞才表达"它们**发生了作用**"。
#   而反应的本质就是"作用" —— 蒸发是水被火烧掉，是那个碰撞动作本身。
#   而且两者是包含关系：并排是碰撞动画的第一帧，做碰撞天然包含另一个方案。
#
# ⚠️ 动画时长和**锁定**时长是**故意解耦**的，别把它们当成一个值：
## ⚠️ 这个值跟着**图标尺寸**走：图标 2026-10-07 从 24x24 升到 32x32，
##    两个图标的半宽从 12 变成 16，原来 14 的偏移会让它们**一开场就重叠**。
##    改成 18 是维持原观感：相撞前两图标边缘留 4px 缝（旧 28-24，新 36-32）。
const REACTION_SPREAD := 18.0                            ## 相撞前两图标各自的水平偏移
const REACTION_FLASH := Color(2.8, 2.8, 2.8, 1.0)        ## 撞上瞬间的亮度
const REACTION_PUNCH_SCALE := 1.5                        ## 撞上瞬间一起放大到几倍
## 头顶图标的 y 偏移 —— 必须和 tools/build_level.gd 里给两个图标设的值一致
## ⚠️ 同样跟着图标尺寸走：24 -> 32 之后，图标底部到中心的距离从 12 变 16，
##    -36 会让图标**压进精英头顶 4px**（主体顶在 -24），所以抬到 -42（底部 -26，留 2px 缝）。
const ICON_Y := -42.0

## 动画三段时长（用户 10-07：撞完要"缓慢上升然后淡化消失"）
const REACTION_HIT_TIME := 0.15       ## 相向而撞
const REACTION_BURST_TIME := 0.10     ## 撞上瞬间的放大 + 爆亮
## 上升 + 淡出。
## "上升"这个动作本身就是**蒸发**的视觉隐喻 —— 两个元素撞完化成一缕烟飘走，
## 比单纯"多停一会儿"更像回事。同时它把视觉停留时间拉长到看得清。
const REACTION_RISE_TIME := 0.55
## 上升距离（像素）。飘得够高，才不会和"动画播完后新挂上的附着图标"叠在一起。
const REACTION_RISE := 30.0

## 附着**锁定**时长 —— 和上面的动画时长**故意无关**。
##
## 用户 10-07 把动画拉长到约 0.8 秒（撞 + 爆 + 飘），但锁定必须留在 0.3 秒：
## 锁 0.8 秒会让战斗明显发卡，玩家砍上去挂不上元素，第一反应是"这游戏有 bug"，
## 而不是"我被锁了"。**锁定的目的是卡住连招节奏，不是播完动画。**
const REACTION_LOCK := 0.3

## 受击闪白：用大于 1 的分量，让精灵在偏暗背景上"炸"一下（modulate 允许超 1）
const HIT_FLASH := Color(2.2, 2.2, 2.2, 1.0)
const HIT_FLASH_TIME := 0.07     ## 闪白时长
const HIT_PUNCH_SCALE := 0.22    ## 受击瞬间放大比例（"打得动"的手感）
const HIT_PUNCH_BACK := 0.09     ## 回弹时间

# ── 受击击退（用户 2026-10-07 排期："可以安排上日程"）──
#
# 要解决的手感问题（用户原话）："4 刀手感感觉不出来，因为没做受击动作，
# 只有变色和改大小"。分析：现在砍 4 刀本质是**原地按 4 次 J** ——
# **没有空间变化就没有节奏**。
#
# ⭐ 关键设计：位移是**真的**（退到新位置停住），"回弹"只是过冲后微回。
#    如果弹回原位，那就只是原地抖一下（= 强化版震颤），
#    产生不出用户认同的那个价值 —— 把"多砍几刀"从重复劳动变成
#    **走位：砍 → 它退 → 追 → 再砍**。
const KNOCKBACK_DIST := 28.0        ## 每次受击后退的净距离（像素）
const KNOCKBACK_OVERSHOOT := 1.2    ## 先退过头到 DIST*1.2，再弹回 DIST（"Q 弹"感的来源）
const KNOCKBACK_OUT_TIME := 0.06    ## 退出去的时间（必须短，慢了就不像"被打飞"）
const KNOCKBACK_BACK_TIME := 0.08   ## 回弹时间
#
# ⚠️ 两段之和**必须**短于 Player 的 ATTACK_COOLDOWN(0.26)：
#    否则连砍时上一段还没跑完就要开下一段，位置会打架。
#    测试里钉死了这个**常量关系** —— 而不是去数物理帧（那样会随机失败）。

# ── 死亡动画（两段）──
# 提成常量，是因为头顶的**附着图标要跟它同步淡出**（用户 2026-10-07 的设计）：
# 敌人 0.26 秒消失，附着也用 0.26 秒消失 —— 一起生、一起死，语义才自洽。
const DEATH_FLASH_TIME := 0.10   ## 先"烧成金橙"
const DEATH_FADE_TIME := 0.16    ## 再淡出
const DEATH_FLASH_COLOR := Color(1.8, 0.9, 0.3, 1.0)

## 附着状态下敌人身上的颜色（火 = 偏红，水 = 偏蓝）。
## 做成"底色"而不是直接 tween 到它，是为了和受击闪白共存：
## 闪白结束后要回到**附着色**，而不是回到白色。
const AURA_COLORS := {
	"fire": Color(1.55, 0.72, 0.55, 1.0),
	"water": Color(0.62, 0.86, 1.60, 1.0),
}
const AURA_DEFAULT_COLOR := Color(1.25, 1.05, 0.95, 1.0)   ## 未登记元素的兜底色
const TINT_CLEAR := Color(1, 1, 1, 1)

# ── 元素反应（第一版只有「蒸发」）──
#
# key   = 敌人身上**已有**的附着
# value = { 打上来的元素: 反应名 }
#
# 双向都登记：火附着 + 水打 = 蒸发，水附着 + 火打 = 蒸发。
# （原神里两者倍率不同，这里第一版不区分 —— 在"一击必杀"为底子的游戏里，
#   先让"能反应"这件事成立；数值分层等有第二个精英 / Boss 时再说。）
const REACTIONS := {
	"fire": {"water": "vaporize"},
	"water": {"fire": "vaporize"},
}

## 蒸发的额外伤害（"重击"级）：一刀总共扣 1 + 1 = 2 血。
## 为什么是 +1：精英 4 血，蒸发一刀打掉一半、两刀蒸发就能解决 ——
## 明显强于普通攻击，又没强到"会切元素就无脑赢"。
const VAPORIZE_BONUS := 1

## 蒸发时的强化受击反馈（比普通受击更炸，让玩家一眼看出"这一刀不一样"）
const VAPORIZE_FLASH := Color(2.8, 2.8, 2.8, 1.0)
const VAPORIZE_PUNCH := 0.45
const VAPORIZE_FLASH_TIME := 0.10

## 头顶附着图标的闪烁周期（单程时长，一次亮灭 = 2 倍）
const AURA_BLINK_TIME := 0.26
## 图标贴图目录。文件名 = 元素名（fire.png / water.png …），由
## tools/gen_element_icons.py 生成，见 art/elements/。
const AURA_ICON_DIR := "res://art/elements/"

var hp := MAX_HP

## 木桩模式（用户 2026-10-07 要的"无限血木桩"，用来反复试各种元素反应）。
##
## 打开后有两个差别：
##   1. 血打空**不会死**，而是立刻回满 —— 受击反馈和反应动画照常播，
##      所以"打空一轮"在视觉上是看得见的，不是无声无息。
##   2. **不伤害玩家** —— 拿木桩测反应时被自己测的东西撞死，那太烦了。
##
## ⚠️ 默认 false（= 正常精英）。由 tools/build_level.gd 在造实例时打开。
##    这样"生产行为"是代码默认值、"测试行为"是地图数据，两者不会搞混。
##
## ⚠️⚠️ **必须是 @export**（2026-10-07 修的 bug）：
##    `PackedScene.pack()` **只序列化 @export 变量** —— 普通脚本变量会被**静默丢弃**。
##    原来它是普通 var，于是生成器里那句 `elite.set("is_dummy", true)` 一打包就没了，
##    场景文件里从来没有这个属性 → 运行时恒为 false
##    （所以"木桩血打空回满"从加上那天起**就没生效过**）。
##    加了 @export 之后，生成器一跑就会把 `is_dummy = true` 写进 main.tscn。
@export var is_dummy := false:
	set(value):
		is_dummy = value
		_sync_dummy_danger()

var _dead := false
var _spawn_position := Vector2.ZERO
var _base_scale := Vector2.ONE
var _hit_tween: Tween = null
## 击退用**独立**的 tween。
## ⚠️ 不能和 _hit_tween 共用一个：那个在管"闪白 + 缩放"，
##    共用的后果是连砍时互相 kill —— 要么击退被掐掉，要么缩放动画半路失踪。
var _knock_tween: Tween = null

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
var reaction_icon: Sprite2D
var _aura_tween: Tween = null
var _reaction_tween: Tween = null
var _reaction_left := 0.0      ## >0 表示处在反应锁定窗口里（这段时间不挂新附着）

## 反应动画"经历过哪些阶段"的日志（调试 / 测试用）。
##
## ⚠️ 为什么要有它：**headless 测试里"物理帧"和"渲染帧"不同步** ——
##    Tween 是按**渲染帧的真实时间**推进的，而测试只能 await physics_frame。
##    一次 await 之间可能跑过好几个渲染帧，所以**没法靠数物理帧判断动画进度**
##    （实测：等 26 个物理帧后，0.8 秒的动画已经播完 84%）。
##    结论：动画必须自己**上报状态**，测试读状态而不是猜时间。
var reaction_phases_seen: Array[String] = []


func _ready() -> void:
	danger = get_node_or_null("Danger") as Area2D
	body_shape = get_node_or_null("Body/Shape") as CollisionShape2D
	visual = get_node_or_null("Body/Visual") as CanvasItem
	aura_icon = get_node_or_null("AuraIcon") as Sprite2D
	reaction_icon = get_node_or_null("ReactionIcon") as Sprite2D
	_spawn_position = global_position
	if visual:
		_base_scale = visual.scale

	add_to_group("enemy")
	add_to_group("elite")      # 单独标记：关卡逻辑和测试可以只找精英
	hp = MAX_HP

	if danger:
		danger.body_entered.connect(_on_danger_body_entered)
		_sync_dummy_danger()      # 进树后才拿得到 danger，所以在这里补一次


## 让"木桩不伤害玩家"在**任何**设置 is_dummy 的时机都成立。
##
## ⚠️ 2026-10-07 修：原来是 `if is_dummy: danger.monitoring = false`（只写单向），
##    配上"is_dummy 没被序列化"那个 bug，实际效果是：
##      运行时 is_dummy = false（血打空照样死），但 _ready() 的副作用
##      `monitoring = false` 是 **Area2D 的内置属性**、被存进了场景文件 →
##      玩家遇到的是"**不会伤害你、但会正常死**"的半吊子精英。
##    现在改成双向显式同步：不管 is_dummy 来自场景、代码还是测试，
##    monitoring 都跟着走。
func _sync_dummy_danger() -> void:
	if danger != null:
		danger.monitoring = not is_dummy


## 被玩家的攻击判定框罩住时调用（Player.gd 会向上找 "enemy" 组的祖先，所以这里就是根节点）
##
## `_element` 现在只收不用；等做元素反应（蒸发 / 融化 / 超载…）时，
## 就在这里判断"这一刀的元素是不是它的弱点 / 能不能破它的盾"。
## 签名带默认值是为了兼容无参调用（测试和生成器都会这么调）。
func kill(element: String = "") -> void:
	if _dead:
		return

	# ── 1) 先算反应：必须在动附着之前算，因为反应依赖"敌人身上原本挂着什么" ──
	var reaction := resolve_reaction(element)

	# ── 2) 伤害：蒸发是"重击" ──
	var damage := 1 + (VAPORIZE_BONUS if reaction == "vaporize" else 0)

	# ── 3) 附着处理 ──
	if element != "":
		if reaction != "":
			# 反应会**消耗掉附着**（原神也是这个规则）。
			# 于是想再蒸发就得重新挂火 —— 这给出"火 → 水 → 火 → 水"的节奏。
			# 视觉上播"两个图标相撞"，并把附着锁住 0.3 秒。
			# ⚠️ _clear_aura() 会把 _aura_element 清空，所以要先记下旧元素。
			var old_element := _aura_element
			_clear_aura()
			_play_reaction_anim(old_element, element)
			_reaction_left = REACTION_LOCK
		else:
			_apply_aura(element)

	# ── 4) 扣血（蒸发可能打过头，clamp 到 0，否则测试和 HUD 会看到负数）──
	hp = maxi(hp - damage, 0)
	damaged.emit(hp)
	if reaction != "":
		reacted.emit(reaction, damage)

	if hp > 0:
		_play_hit_reaction(reaction != "")
		return

	# ── 木桩：血打空就立刻回满，永远不死 ──
	# 用**强化反馈**（strong=true）让"打空一轮"这件事看得见 ——
	# 否则血条突然跳回满，玩家会以为 HUD 出 bug 了。
	if is_dummy:
		hp = MAX_HP
		damaged.emit(hp)
		_play_hit_reaction(true)
		return

	_die()


## 判断"带着 attacking 元素砍过来"会不会触发反应，返回反应名（无反应返回 ""）
##
## 抽成公开方法：HUD、特效、测试都想知道"这一刀会发生什么"，
## 而不该各自复制一份反应表 —— 那样迟早会和这里不一致。
func resolve_reaction(attacking: String) -> String:
	if attacking == "" or _aura_element == "" or attacking == _aura_element:
		return ""
	var table: Dictionary = REACTIONS.get(_aura_element, {})
	return table.get(attacking, "")


## 挂上 / 刷新元素附着
##
## 用户 2026-10-06 的规则：持续 2 秒；2 秒内**再次被同元素打中则计时重置**。
## 注意是"重置回 2 秒"而不是"累加" —— 否则连续攻击会把附着时间堆到离谱，
## 将来做反应时会变成"永远挂着火"。
func _apply_aura(element: String) -> void:
	# ⭐ 反应刚发生的那 0.3 秒里**不挂新附着**（用户 10-07 的设计）。
	#    既是避免相撞动画被新元素顶掉，也让连招有呼吸 —— 不是无脑连点。
	if _reaction_left > 0.0:
		return
	# 锁定早已过去，但**飘散动画可能还在播**（动画 ~0.8 秒 > 锁定 0.3 秒）——
	# 新附着要接管图标，先把残留动画收掉，否则两个 tween 会抢同一个节点。
	_stop_reaction_anim()
	_aura_element = element
	_aura_left = AURA_DURATION
	_refresh_aura_tint()
	_show_aura_icon(element)      # 先**常亮** —— 此刻剩余 3 秒，还没到警告期
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
	aura_icon.modulate = Color(1, 1, 1, 1)     # 常亮
	# ⚠️ 这里**故意不启动闪烁** —— 闪烁是"快没了"的警告，
	#    交给 _physics_process 在剩余时间掉到 AURA_BLINK_AT 以下时才开启。
	#    （用户 10-07 的设计：前段常亮、后段才闪。）


## 进入警告期，开始闪烁
##
## 加守卫是为了让它能被 _physics_process 每帧安全调用 —— 只启动一次。
func _start_aura_blink() -> void:
	if aura_icon == null or _aura_tween != null:
		return
	_aura_tween = create_tween().set_loops()
	_aura_tween.tween_property(aura_icon, "modulate:a", 0.25, AURA_BLINK_TIME)
	_aura_tween.tween_property(aura_icon, "modulate:a", 1.00, AURA_BLINK_TIME)


func _stop_aura_blink() -> void:
	if _aura_tween != null and _aura_tween.is_valid():
		_aura_tween.kill()
	_aura_tween = null
	if aura_icon != null:
		aura_icon.visible = false
		aura_icon.modulate = Color(1, 1, 1, 1)
		aura_icon.position = Vector2(0, ICON_Y)
		aura_icon.scale = Vector2.ONE


## 元素反应的视觉：两个图标从两侧向中间**相撞**，然后一起消失
##
## 用户 10-07 的方案 B。为什么不是"两个图标并排显示"：
##   并排只表达"两个元素共存"，碰撞才表达"它们发生作用了" ——
##   而反应的本质就是"作用"（蒸发 = 水被火烧掉，是那个碰撞动作本身）。
##   而且两者是包含关系：并排是碰撞动画的第一帧，做碰撞天然包含另一个方案。
##
## 撞完一起消失，和"反应消耗掉附着"这条机制保持一致。
## ⚠️ 新元素的贴图缺失时直接不播（不崩）—— 和 AuraIcon 一样的容错策略。
func _play_reaction_anim(old_element: String, new_element: String) -> void:
	if aura_icon == null or reaction_icon == null:
		return

	var tex_path := AURA_ICON_DIR + new_element + ".png"
	if not ResourceLoader.exists(tex_path):
		return

	# 掐掉残留的闪烁/动画，保证这次从干净状态起播
	_stop_aura_blink()
	if _reaction_tween != null and _reaction_tween.is_valid():
		_reaction_tween.kill()

	# AuraIcon 带着**旧元素**的贴图，从中心偏左起步
	aura_icon.visible = true
	aura_icon.modulate = Color(1, 1, 1, 1)
	aura_icon.scale = Vector2.ONE
	aura_icon.position = Vector2(-REACTION_SPREAD, ICON_Y)

	# ReactionIcon 带**新元素**，从右边飞进来
	reaction_icon.texture = load(tex_path)
	reaction_icon.visible = true
	reaction_icon.modulate = Color(1, 1, 1, 1)
	reaction_icon.scale = Vector2.ONE
	reaction_icon.position = Vector2(REACTION_SPREAD, ICON_Y)

	_reaction_tween = create_tween()
	reaction_phases_seen.clear()
	# ⚠️ 用 tween.parallel()（不是给 Tweener 调 set_parallel —— 那个方法在 Tween 上，
	#    CallbackTweener 没有它，实测会报 "Nonexistent function 'set_parallel'"）。
	# parallel() 的语义是"下一个 tweener 与前一个并行"。

	# 1) 相向而撞
	_reaction_tween.tween_property(aura_icon, "position:x", 0.0, REACTION_HIT_TIME)
	_reaction_tween.parallel().tween_property(reaction_icon, "position:x", 0.0, REACTION_HIT_TIME)

	# 2) 撞上的一瞬：记录阶段 + 一起放大爆亮（"反应发生了"）
	_reaction_tween.chain().tween_callback(_mark_phase.bind("hit"))
	_reaction_tween.parallel().tween_property(aura_icon, "scale", Vector2.ONE * REACTION_PUNCH_SCALE, REACTION_BURST_TIME)
	_reaction_tween.parallel().tween_property(reaction_icon, "scale", Vector2.ONE * REACTION_PUNCH_SCALE, REACTION_BURST_TIME)
	_reaction_tween.parallel().tween_property(aura_icon, "modulate", REACTION_FLASH, REACTION_BURST_TIME)
	_reaction_tween.parallel().tween_property(reaction_icon, "modulate", REACTION_FLASH, REACTION_BURST_TIME)

	# 3) **缓慢上升 + 淡化**（用户 10-07 要的效果）
	#
	# 上升这个动作本身就是**蒸发**的视觉隐喻：两个元素撞完化成一缕烟飘走，
	# 比单纯"多停一会儿"更像回事；同时它把视觉停留时间拉长到看得清。
	# 两个图标**一起**升，保持"它们是一体的反应产物"的感觉。
	_reaction_tween.chain().tween_callback(_mark_phase.bind("burst"))
	_reaction_tween.parallel().tween_property(aura_icon, "position:y", ICON_Y - REACTION_RISE, REACTION_RISE_TIME)
	_reaction_tween.parallel().tween_property(reaction_icon, "position:y", ICON_Y - REACTION_RISE, REACTION_RISE_TIME)
	_reaction_tween.parallel().tween_property(aura_icon, "modulate:a", 0.0, REACTION_RISE_TIME)
	_reaction_tween.parallel().tween_property(reaction_icon, "modulate:a", 0.0, REACTION_RISE_TIME)

	_reaction_tween.chain().tween_callback(_finish_reaction_anim)


## 记录动画进入某个阶段（挂在 tween 上，由动画自己上报）
func _mark_phase(phase: String) -> void:
	reaction_phases_seen.append(phase)


## 动画播完：记下最后一段，然后复位图标
func _finish_reaction_anim() -> void:
	reaction_phases_seen.append("rise")
	_hide_reaction_icons()


## 掐掉反应动画并复位图标
##
## ⚠️ 必须在新附着进来时调用：动画有 ~0.8 秒，而锁定只有 0.3 秒 ——
##    也就是说**动画还在飘的时候，玩家就可能挂上新元素了**。
##    那时 _show_aura_icon 会去动 aura_icon，而残留的 reaction_tween 也在动同一个节点，
##    两个 tween 抢一个节点 = 位置/透明度打架。
func _stop_reaction_anim() -> void:
	if _reaction_tween != null and _reaction_tween.is_valid():
		_reaction_tween.kill()
	_reaction_tween = null
	_hide_reaction_icons()


## 把两个图标复位并隐藏（动画结束 / 复位 / 死亡时都走这里）
func _hide_reaction_icons() -> void:
	for n in [aura_icon, reaction_icon]:
		if n == null:
			continue
		n.visible = false
		n.modulate = Color(1, 1, 1, 1)
		n.scale = Vector2.ONE
		n.position = Vector2(0, ICON_Y)


## 附着倒计时
##
## 用 _physics_process 而不是 _process：物理帧率固定 60Hz，计时更稳；
## 而且它同样受 Engine.time_scale 影响 —— 子弹时间下附着也跟着变慢，这是对的
## （世界整体放慢，不该只有玩家这边的状态在正常走）。
func _physics_process(delta: float) -> void:
	# 反应锁定窗口先递减 —— 它和附着是两个独立计时，附着为空时也要走
	_reaction_left = maxf(_reaction_left - delta, 0.0)

	if _aura_element == "":
		return
	_aura_left -= delta
	if _aura_left <= 0.0:
		_clear_aura()
		return
	# 剩余时间掉进警告期 → 开始闪。
	# _start_aura_blink 自带守卫（tween 已存在就直接返回），所以每帧调是安全的。
	if _aura_left <= AURA_BLINK_AT:
		_start_aura_blink()


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
##
## strong = true 时用蒸发专用的参数（更亮、弹得更大），
## 让"这一刀触发了反应"在视觉上立刻可辨 —— 否则玩家只会觉得"伤害好像高了一点？"
func _play_hit_reaction(strong: bool = false) -> void:
	if visual == null:
		return

	var flash := VAPORIZE_FLASH if strong else HIT_FLASH
	var flash_time := VAPORIZE_FLASH_TIME if strong else HIT_FLASH_TIME
	var punch := VAPORIZE_PUNCH if strong else HIT_PUNCH_SCALE

	# 先掐掉上一段受击动画：攻击冷却只有 0.26 秒，而这段动画约 0.16 秒，
	# 连砍时两段会重叠，掐掉才不会让 scale 越叠越大、最后回不了位。
	if _hit_tween != null and _hit_tween.is_valid():
		_hit_tween.kill()
	visual.scale = _base_scale

	_hit_tween = create_tween()
	_hit_tween.tween_property(visual, "modulate", flash, flash_time)
	_hit_tween.parallel().tween_property(visual, "scale", _base_scale * (1.0 + punch), flash_time)
	# 回到**当前底色**（有附着就是元素色），而不是硬编码回白色 ——
	# 否则每挨一刀，元素附着的视觉就会闪回白色再变回来，看着像掉状态。
	_hit_tween.tween_property(visual, "modulate", _base_modulate(), HIT_PUNCH_BACK)
	_hit_tween.parallel().tween_property(visual, "scale", _base_scale, HIT_PUNCH_BACK)


## 受击击退：朝 dir 退一段，过冲后微回，**停在新位置**。
##
## 由 Player.gd 在命中时调用 —— 只有玩家知道自己在敌人的哪一侧。
##
## ⚠️ 这里**故意不检查 _dead**：致死的那一刀也要退，否则"最后一刀"反而是
##    最没劲的一刀。死亡流程动的是 visual 的 modulate/visible，本方法动的是
##    节点的 global_position，两者互不干扰。
##
## ⚠️ 精英是 Node2D、没有物理体，所以位移是**直接改坐标**，不走 velocity。
##    副作用（已知，先接受）：被推到平台边缘外也会**悬空**（没有重力）。
##    真要处理得等"关卡边界"一起做；现在宁可让它悬空，也不要它掉下去消失
##    —— 掉下去就找不回来了，检查点复位链路会跟着变得难查。
func knockback(dir: float) -> void:
	if dir == 0.0:
		return
	var d := signf(dir)

	# 连砍时上一段还在跑：掐掉它，从**当前实际位置**再退。
	# 这样连续砍会把它一路推走（正是"追着砍"的来源），
	# 而不是把位移叠加成一次飞出屏幕。
	if _knock_tween != null and _knock_tween.is_valid():
		_knock_tween.kill()

	var from := global_position
	var peak := from + Vector2(d * KNOCKBACK_DIST * KNOCKBACK_OVERSHOOT, 0.0)
	var rest := from + Vector2(d * KNOCKBACK_DIST, 0.0)

	_knock_tween = create_tween()
	_knock_tween.tween_property(self, "global_position", peak, KNOCKBACK_OUT_TIME)
	_knock_tween.tween_property(self, "global_position", rest, KNOCKBACK_BACK_TIME)


## 给测试读的击退参数（避免测试里再写一份数字）
func get_knockback_dist() -> float:
	return KNOCKBACK_DIST


## 给测试读的"击退动画总时长"：测试用它钉死"连砍不会和上一段打架"
func get_knockback_total_time() -> float:
	return KNOCKBACK_OUT_TIME + KNOCKBACK_BACK_TIME


## 给测试读的击退 tween（验"真的动了"，而不是靠采样动画中间帧）
func get_knock_tween() -> Tween:
	return _knock_tween


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
		tw.tween_property(visual, "modulate", DEATH_FLASH_COLOR, DEATH_FLASH_TIME)
		tw.tween_property(visual, "modulate:a", 0.0, DEATH_FADE_TIME)
		tw.tween_callback(_hide_on_death)
	else:
		_hide_on_death()

	# 头顶的元素图标跟着一起收（用户 2026-10-07 报的 bug）
	_fade_icons_on_death()

	died.emit()


func _hide_on_death() -> void:
	if visual:
		visual.visible = false


## 死亡时把头顶的元素图标一起收掉。
##
## 现象（用户 2026-10-07 报的）："怪物死亡以后，头上的元素符号仍然存在"。
## 根因有**两层**：
##   ① `_hide_on_death()` 只隐藏了 `visual`（Body/Visual），而图标是挂在**根节点**上的
##      —— 那是**故意的**（Body 受击会缩放，图标挂那儿会跟着抖，见 §2.12）——
##      于是敌人消失了、图标留在原地继续闪。
##   ② 附着状态也没清：`_aura_element` 还在，`_physics_process` 继续给那 3 秒计时，
##      所以图标会一直闪到附着**自然耗尽**才自己收掉（最长 3 秒）。
##
## ⭐ 为什么选"淡出"而不是"瞬间消失"（用户问的，三条理由）：
##   ① **本项目的"消失"从来没硬切过** —— 反应动画是"相撞 → 上升 → 淡化"，
##      敌人死亡是"金橙 → 淡化"。瞬间消失在这里只出现过一次，就是 bug 本身。
##   ② **附着是"挂在敌人身上"的状态**：敌人用 0.26 秒消失，附着就用同样的时间跟着走
##      —— 一起生、一起死，语义才自洽。
##   ③ **不抢戏**：死亡那 0.26 秒里已经有三个动作在抢注意力（金橙闪 / 淡化 / 受击回弹），
##      图标再来个"上升 30px"就过载了。所以这里用**原地淡出**，
##      把"上升"这个动作留给元素反应。
##
## ⚠️ 这里**故意不调 `_clear_aura()`**：它内部的 `_refresh_aura_tint()` 会把
##    `visual.modulate` 设回白色，正好**打断死亡动画的金橙淡出**
##    （死亡 tween 不是 `_hit_tween`，不受那个守卫保护）。
##    所以附着状态照样清，但"改敌人颜色"这件事留给死亡动画自己。
func _fade_icons_on_death() -> void:
	_aura_element = ""
	_aura_left = 0.0
	_reaction_left = 0.0

	# 图标上的 tween 先全掐掉，否则会和新的淡出抢同一个节点
	if _aura_tween != null and _aura_tween.is_valid():
		_aura_tween.kill()
	_aura_tween = null
	if _reaction_tween != null and _reaction_tween.is_valid():
		_reaction_tween.kill()
	_reaction_tween = null

	var fade := DEATH_FLASH_TIME + DEATH_FADE_TIME      # 和敌人消失同步（0.26 秒）
	for n in [aura_icon, reaction_icon]:
		var icon := n as Sprite2D
		if icon == null or not icon.visible:
			continue
		var tw := create_tween()
		tw.tween_property(icon, "modulate:a", 0.0, fade)
		tw.tween_callback(func() -> void: icon.visible = false)


## 复位：回到出生点并**满血**（检查点复活时由 Main.gd 调用）
##
## revive_dead = true 时连已死的也复活 —— 保证每次重开都是同样的初始状态，
## 否则"死一次少一个敌人"，关卡难度会随重开次数漂移。
func reset_enemy(revive_dead: bool = true) -> void:
	# ⚠️ 顺序很关键：**先掐掉击退动画，再设位置**。反了的话，
	#    "复位到出生点"会被还在跑的 tween 一路拽回它退到的位置 ——
	#    玩家死一次，精英就永久挪窝（而且不报错，只是每次复活位置都不一样）。
	#    这是交接文件里"受击回弹动画污染断言"的同一类坑。
	if _knock_tween != null and _knock_tween.is_valid():
		_knock_tween.kill()
	_knock_tween = null

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

	# 反应状态也要清干净：否则复活回来可能还挂着"锁定"或者半个相撞动画
	_reaction_left = 0.0
	if _reaction_tween != null and _reaction_tween.is_valid():
		_reaction_tween.kill()
	_reaction_tween = null
	_hide_reaction_icons()

	if _hit_tween != null and _hit_tween.is_valid():
		_hit_tween.kill()

	if danger:
		# 木桩复位后也**保持不伤人**，否则复活一次它就又开始撞玩家
		danger.set_deferred("monitoring", not is_dummy)
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


## 血量上限 —— 供 HUD 显示 "3/4" 用（常量取不到，必须走方法）
func get_max_hp() -> int:
	return MAX_HP


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


## 附着总时长 —— 供测试用。
## ⚠️ 必须走方法而不是 `elite.get("AURA_DURATION")`：
##    Object.get() 只能取**属性**，取不到**常量**（常量在脚本的 constant map 里，
##    不在属性表里），直接 get 会拿到 null 然后在算术里炸掉。
func get_aura_duration() -> float:
	return AURA_DURATION


## 剩余多少秒时开始闪（警告期阈值）—— 供测试用，理由同上
func get_aura_blink_at() -> float:
	return AURA_BLINK_AT


## 反应锁定窗口的剩余时间 —— 供测试断言"锁定期内挂不上附着"
func get_reaction_left() -> float:
	return _reaction_left


## 反应锁定时长 —— 供测试用（常量取不到，必须走方法）
func get_reaction_lock() -> float:
	return REACTION_LOCK


## 反应动画的**总时长**（撞 + 爆 + 上升）—— 供测试等待动画播完用。
## 注意它比 REACTION_LOCK 长得多，两者不能混为一谈。
func get_reaction_anim_time() -> float:
	return REACTION_HIT_TIME + REACTION_BURST_TIME + REACTION_RISE_TIME


## 这次反应动画经历过的阶段（顺序：hit → burst → rise）—— 供测试判断动画有没有走完。
## ⚠️ 测试**必须**读这个，不能靠数物理帧：Tween 按渲染帧的真实时间推进，
##    而 headless 下物理帧与渲染帧不同步（实测等 26 个物理帧，0.8 秒的动画已播完 84%）。
func get_reaction_phases() -> Array:
	return reaction_phases_seen


## 上升阶段开始的时间点 —— 供调试参考
func get_reaction_rise_start() -> float:
	return REACTION_HIT_TIME + REACTION_BURST_TIME


## 第二个图标（反应动画里"新元素"那个）—— 供测试断言"两个图标都出现了"
func get_reaction_icon() -> Sprite2D:
	return reaction_icon


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
