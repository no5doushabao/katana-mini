extends CharacterBody2D

## 切换附魔元素时发出（HUD / 音效 / 粒子可以接）
signal element_changed(element: String)
signal hp_changed(hp: int, max_hp: int)   ## 血量变化时发出（HUD 血条刷新用）

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

# ── 生命值 / 受击（2026-10-08 阿包拍板：主角不再"一击必杀"）──
# 三档伤害 → 三档反馈。数值与抖动参数**全做成常量**：调手感只改这里，不碰逻辑。
# ⚠️ 坠落走独立入口 take_fall_damage()：**失去全部生命**，抖动比"大伤害"再重一档。
const MAX_HP := 20                 ## 总血量（阿包定 20，可调）
const IFRAME_TIME := 0.6           ## 受击后无敌时间 —— 没有它，贴着敌人会 1 帧掉光血
const HURT_FLASH_TIME := 0.22      ## 受击闪红时长（小伤害**不抖屏**，靠这个给反馈）
const HURT_FLASH_COLOR := Color(1.0, 0.35, 0.35, 1.0)   ## 受击时角色染成的红（modulate 乘法）

const HURT_SMALL := 1              ## 小伤害：蹭一下（杂兵 / 巡逻兵）
const HURT_MEDIUM := 3             ## 中伤害：明显挨了一下（精英）
const HURT_LARGE := 6              ## 大伤害：出事了（移动危险物）

const SHAKE_MEDIUM_PX := 3.0       ## 中伤害：抖 3 像素
const SHAKE_MEDIUM_TIME := 0.25    ##          持续 0.25 秒
const SHAKE_LARGE_PX := 7.0        ## 大伤害：抖 7 像素
const SHAKE_LARGE_TIME := 0.45     ##          持续 0.45 秒
const SHAKE_FALL_PX := 8.0         ## 坠落：抖 8 像素
const SHAKE_FALL_TIME := 0.5       ##       持续 0.5 秒

# ── 屏幕抖动（trauma 模型）──
# trauma 从 1 衰减到 0；幅度按"整像素阶梯"给，位移再从阶梯里随机跳。
#
# ⚠️ 像素画的两条天条：**只平移、只整数**。旋转抖会让整幅画面重采样（糊）；
#    抖非整数像素会让像素在亚像素级漂移（画面像"翻滚/闪烁"）。
#
# ⭐ 为什么幅度必须"先量化成整数阶梯、再从阶梯里随机跳"（2026-10-08 实测）：
#    直觉写法是"连续噪声 × 幅度，再 roundf"——采样 60 帧发现**只有 2 帧真在动**，
#    其余全被 roundf 抹成 0px，等于没抖、而且不报错。**量化要放在"幅度"这一层。**
const SHAKE_POWER := 2.0           ## 幅度 = max_px × trauma^power（平方 = 尾部收得干脆）
const SHAKE_DEFAULT_PX := 6.0      ## add_trauma() 不带参数时的默认幅度
const SHAKE_DEFAULT_TIME := 0.45   ## add_trauma() 不带参数时的默认时长（秒）

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

# ── 元素附魔（第一版：火 / 水）──
# 用户 2026-10-06 拍板的两件事：
#   ① 元素的表现挂在**攻击范围**上，不是角色本体
#      （原话："用小月牙的形状来模拟攻击范围"）
#   ② 10-06 晚上加"一个按钮循环切换属性"：一开始是火，按一下变水，再按又变回火
#
# ⚠️ 切换用**数组 + 索引**，不写死"火 ↔ 水"：
#    用户的总体设计是"每关自选 3 种元素"，到时候只要换 ELEMENTS 的内容
#    （或者按关卡数据填），切换逻辑一行都不用改。
const ELEMENT_FIRE := "fire"
const ELEMENT_WATER := "water"

## 可切换的元素 —— 按 L 在这个列表里循环
const ELEMENTS := [ELEMENT_FIRE, ELEMENT_WATER]

## 元素 → 月牙颜色。加新元素就在这张表里加一行，_draw() 不用改。
const ELEMENT_COLORS := {
	ELEMENT_FIRE: Color(1.0, 0.38, 0.18, 0.80),     # 橙红
	ELEMENT_WATER: Color(0.32, 0.72, 1.0, 0.80),    # 亮蓝
}
const ARC_DEFAULT_COLOR := Color(1, 1, 1, 0.70)    ## 没登记的元素：白色兜底
const ARC_IDLE_COLOR := Color(1, 1, 1, 0.05)       ## 非攻击时：几乎看不见的残影，方便对齐调试
const TINT_CLEAR := Color(1, 1, 1, 1)              ## 角色本体的"无色"

## 切换后的冷却。第一版是 0（不冷却）——
## 元素反应才是这个系统的核心，卡切换只会让手感变涩。需要时再调这个数。
const ELEMENT_SWITCH_CD := 0.0
## 切换瞬间角色闪一下**新元素**的颜色。
## 它和"攻击时月牙变色"是两件事，别混淆：
##   切换闪光 = "我现在是什么属性"；月牙颜色 = "这一刀是什么属性"。
const SWITCH_FLASH_TIME := 0.20

## 月牙几何。
##
## 这组数是拿对比图试出来的，三个约束互相拉扯，调的时候都要照顾到：
##   1. 内半径要 > 角色视觉半宽（24px 精灵 x scale 1.5 = 半宽 18），否则糊在角色脸上
##   2. 外半径要 ≈ 或略大于判定框外缘（ATTACK_OFFSET_X 33 + 52/2 = 59），
##      否则玩家会觉得"明明够得到却没打中"
##   3. 内外半径之差决定弧的"厚度"——太厚像竖着的叶子（第一版 32 就是这样），
##      太薄又不像能被"扫到"的范围
## 所以最终取"细弧 + 覆盖判定框外缘"：厚 22，外缘压在 59 上。
const ARC_OUTER_R := 62.0
const ARC_INNER_R := 40.0
const ARC_SPAN_DEG := 84.0        ## 月牙张角（总角度）
const ARC_SEGMENTS := 16          ## 弧线细分数：够平滑，顶点又不多
const ARC_TIP_SHARP := 1.4        ## 两头收尖的陡峭度（1.0=线性收，越大越尖）

var element_index := 0               ## 当前元素在 ELEMENTS 里的下标
var element := ELEMENTS[0]           ## 当前附魔元素（开局是火）
var _switch_cd := 0.0                ## 切换冷却剩余
var _switch_flash := 0.0             ## 切换闪光剩余（>0 时角色染成新元素色）
var _arc_active := false             ## 上一帧月牙是否激活（用来决定要不要重绘）

@onready var shape: CollisionShape2D = $Shape
@onready var attack_area: Area2D = $AttackArea
@onready var camera: Camera2D = get_node_or_null("Camera2D") as Camera2D
@onready var sprite: Sprite2D = get_node_or_null("Visual") as Sprite2D

var _anim_time := 0.0          ## 动画计时器（累加 delta）

var _trauma := 0.0             ## 屏幕抖动"创伤值"（0~1）：每次抖动从 1 衰减到 0
var _shake_max := SHAKE_DEFAULT_PX                  ## 本次抖动的幅度（整数像素）
var _shake_decay := 1.0 / SHAKE_DEFAULT_TIME        ## trauma 每秒衰减量（由"时长"换算）
## 抖动用的独立随机源 —— 不用全局 randi，免得影响敌人巡逻等别处的随机序列
var _shake_rng := RandomNumberGenerator.new()

var hp := MAX_HP               ## 当前生命值（受击扣、复活回满）
var _iframe := 0.0             ## 无敌帧剩余（>0 时免疫伤害）
var _hurt_flash := 0.0         ## 受击闪红剩余

func _ready() -> void:
	add_to_group("player")
	# 攻击判定框罩住敌人时，由这里负责"击杀"。
	# 注意：Area2D 自己只会"知道有东西在里面"，不会做任何事——
	# 必须有人接收信号并执行后果，否则就是"检测到了但没人管"。
	attack_area.body_entered.connect(_on_attack_hit)

	_shake_rng.randomize()

func _physics_process(delta: float) -> void:
	# ⚠️ 抖屏必须放**最前面**（在下面 `if _is_dead: return` 的早退之前）：
	#    死亡那一刻才是最需要抖的时候，写在早退之后 = 死了反而不抖。
	_update_shake(delta)
	# 精灵切帧放最前面：即使死了也要把帧摆对（死亡状态显示下落帧）
	_update_sprite(delta)
	if _is_dead:
		# 死了就把月牙收掉，并把切换闪光清干净
		# （否则会顶着一身元素色躺在那，而且 _switch_flash 也不再递减了）
		if _arc_active:
			_arc_active = false
			queue_redraw()
		_switch_flash = 0.0
		_update_element_visual()
		return

	_tick_timers(delta)
	_update_bullet_time(delta)
	_handle_horizontal(delta)
	_handle_dash(delta)
	_handle_jump(delta)
	_handle_attack(delta)
	_handle_element_switch(delta)

	# ⚠️ 月牙的重绘放在 _handle_attack() **之后**：
	#    _attack_left 是本帧末尾才置位的，而 _draw() 自己不会每帧重画。
	#    只在"激活状态真的变了"时 queue_redraw()，避免每帧重建多边形。
	#    （第一版把染色写进 _update_sprite()，测试实测抓到它**晚一帧**才生效。）
	var arc_now := _attack_left > 0.0
	if arc_now != _arc_active:
		_arc_active = arc_now
		queue_redraw()

	# 元素视觉（切换闪光）同样放在最后 —— _switch_flash 是本帧刚更新的
	_update_element_visual()

	# 重力和下落上限
	if not is_on_floor():
		velocity.y = minf(velocity.y + GRAVITY * delta, MAX_FALL_SPEED)
	elif _dash_left <= 0.0 and velocity.y > 0.0:
		velocity.y = 0.0

	move_and_slide()

# ────────────────────────────── 各子系统 ──────────────────────────────

## 屏幕抖动：抖 max_px 个像素、持续 duration 秒 —— **所见即所得**。
##
## 为什么不用"只给一个 trauma 值"：trauma 会**同时**改幅度和时长，
## 想让"中等伤害抖得轻一点"就会连带把它变成"又轻又短"（实测过：0.5 trauma
## 只抖 0.13 秒，看起来像没抖）。分开两个参数，档位才调得动。
func shake(max_px: float, duration: float) -> void:
	if max_px <= 0.0 or duration <= 0.0:
		return
	_shake_max = max_px
	_shake_decay = 1.0 / duration
	_trauma = 1.0


## 攒"创伤值"（不带幅度/时长参数时走默认值）
func add_trauma(amount: float) -> void:
	_trauma = clampf(_trauma + amount, 0.0, 1.0)


func get_trauma() -> float:
	return _trauma


func get_hp() -> int:
	return hp


func get_max_hp() -> int:
	return MAX_HP


## 受击入口 —— **敌人 / 危险物都该调这个，不要再直接调 die()**。
##
## 伤害值决定反馈档位（"数值 → 反馈"的映射集中在玩家身上，敌人只管"我打多少"）：
##   小(1) = 不抖屏，只闪红 + 血条掉一格（零反馈会让玩家不知道被打中）
##   中(3) = 抖 3px / 0.25s
##   大(6) = 抖 7px / 0.45s
##
## ⚠️ 无敌帧是**必需**的：没有它，贴着敌人时每物理帧扣一次 → 1 帧掉光血。
##    它同时兜住了"重叠状态不变就永不判伤"的老 bug（见 Enemy/Hazard 的轮询判伤）。
func take_damage(amount: int) -> void:
	if _is_dead or amount <= 0:
		return
	if _iframe > 0.0:
		return   # 无敌帧内免疫；**不重置计时**，否则贴着敌人会永远无敌
	hp = maxi(hp - amount, 0)
	_iframe = IFRAME_TIME
	_hurt_flash = HURT_FLASH_TIME
	if amount >= HURT_LARGE:
		shake(SHAKE_LARGE_PX, SHAKE_LARGE_TIME)
	elif amount >= HURT_MEDIUM:
		shake(SHAKE_MEDIUM_PX, SHAKE_MEDIUM_TIME)
	# 小伤害刻意不抖屏：抖动留给"真的疼"，小伤害靠闪红 + HUD 掉格给反馈
	_update_element_visual()   # 立刻闪红（别等下一帧的主循环，否则反馈晚一帧）
	hp_changed.emit(hp, MAX_HP)
	if hp <= 0:
		die()


## 坠落：**失去全部生命**（2026-10-08 阿包定）。
## 单独一个入口，因为它的抖动档位比"大伤害"更重，而且不走"扣血"那套。
func take_fall_damage() -> void:
	if _is_dead:
		return
	hp = 0
	_iframe = IFRAME_TIME
	_hurt_flash = HURT_FLASH_TIME
	shake(SHAKE_FALL_PX, SHAKE_FALL_TIME)
	_update_element_visual()
	hp_changed.emit(hp, MAX_HP)
	die()


## 屏幕抖动：位移挂在 Camera2D.offset 上。
## 相机是玩家的子节点 → 抖的是"画面"，**不影响玩家位置、碰撞、关卡逻辑**（纯表现层）。
## HUD 在 CanvasLayer 里（main.tscn），天然不受相机影响 → UI 不会被抖。
func _update_shake(delta: float) -> void:
	if _trauma <= 0.0:
		if camera:
			camera.offset = Vector2.ZERO   # 收尾必须归零，否则相机永远歪着
		return

	# ⭐ 用**真实时间**衰减：子弹时间把世界放慢 3 倍时，打击反馈不该跟着变慢。
	#    反例：若直接用被缩放的 delta，开慢动作死亡 → 抖屏要 5 秒真实时间才停，
	#    而复活（RESPAWN_DELAY 走的是物理时间）只要 1.5 秒 → 相机歪着复活。
	var real_delta := delta / maxf(Engine.time_scale, 0.05)
	_trauma = maxf(_trauma - _shake_decay * real_delta, 0.0)

	if camera == null:
		return   # 没有相机（测试场景）时照常衰减，只是没东西可抖

	# ⭐ 幅度**量化成整数像素阶梯**，再从阶梯里随机跳 —— 这是实测改出来的：
	#    第一版是"连续噪声 × 幅度，再 roundf"，用 _shake_probe.gd 采样 60 帧发现
	#    绝大部分帧被抹成 0px、只有零星 1px（等于没抖）。
	#    改成整数阶梯后：满 trauma 抖 SHAKE_MAX_OFFSET px，随后逐级收（6→4→2→1→0），
	#    每帧都真在动，而且天生落在整数像素上（像素画不会糊）。
	var max_px := int(roundf(_shake_max * pow(_trauma, SHAKE_POWER)))
	if max_px <= 0:
		camera.offset = Vector2.ZERO
		return
	camera.offset = Vector2(
		float(_shake_rng.randi_range(-max_px, max_px)),
		float(_shake_rng.randi_range(-max_px, max_px)))


func _tick_timers(delta: float) -> void:
	_dash_cd = maxf(_dash_cd - delta, 0.0)
	_attack_cd = maxf(_attack_cd - delta, 0.0)
	_attack_left = maxf(_attack_left - delta, 0.0)
	_jump_buffer = maxf(_jump_buffer - delta, 0.0)
	# 受击相关：无敌帧（"不会一帧掉光血"的关键）与闪红
	_iframe = maxf(_iframe - delta, 0.0)
	_hurt_flash = maxf(_hurt_flash - delta, 0.0)

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
## 纯函数：算击退方向（+1 往右 / -1 往左），也就是"把敌人往远离我的方向推"。
##
## ⭐ 为什么把它抽成 static：**为了可测**。交接文件里最贵的一条教训是
##    "headless 测试里 Tween 按渲染帧推进，别靠数物理帧验证动画"——
##    所以"方向对不对"这条最容易出错的逻辑**直接测纯函数**，
##    而不是去采样动画中间帧（那种断言会随机失败）。
##
## `fallback` 处理玩家与敌人**完全重合**（差值为 0）的情况：按玩家朝向退，
## 不能退成 0 —— 否则这一刀就没有击退，而"贴脸砍"恰恰是最常见的情形。
static func knockback_dir(enemy_x: float, player_x: float, fallback: int) -> float:
	var d := signf(enemy_x - player_x)
	if d == 0.0:
		return float(fallback)
	return d


func _on_attack_hit(body: Node2D) -> void:
	var root := _find_group_ancestor(body, "enemy")
	if root == null:
		return

	# 已经死掉的敌人不再受击：否则"尸体"会被反复推着走（杂兵死了还在地上滑）。
	if root.has_method("is_dead") and root.is_dead():
		return

	# ── 受击击退（用户 2026-10-07 排期）──
	# 用 root 的 global_position 而不是碰撞体 body 的位置 —— body 是子节点。
	# 先击退再 kill：致死的那一刀**也要退**（否则最后一刀最没劲，
	# 而那一刀恰恰是玩家最想看反馈的地方）。knockback 实现里不检查 _dead。
	#
	# ⭐ 2026-10-09：**普攻 / 元素反应分级**（阿包 10-07 的第 2 条判断）。
	#    力度**问敌人一句**（get_knockback_for）—— 它自己知道身上附着着什么、
	#    这一刀会不会触发反应，玩家去查就成了耦合。
	#    ⚠️ 必须"问一句、退一次"：如果让反应那边事后再补一次击退，
	#       会叠加（knockback 是从**当前**位置再退），总距离失控。
	#    ⚠️ 问的时机在 kill() **之前** —— 反应会消耗附着，等反应后再问就问不到了。
	if root.has_method("knockback"):
		var kb_dir := knockback_dir(root.global_position.x, global_position.x, facing)
		if root.has_method("get_knockback_for"):
			root.knockback(kb_dir, root.get_knockback_for(element))
		else:
			root.knockback(kb_dir)

	if root.has_method("kill"):
		# 带上当前附魔元素：杂兵忽略它（保持一击必杀），精英和将来的元素反应会用它。
		# 所有 kill() 实现都带默认值，所以这条调用对旧实现也安全。
		root.kill(element)


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


## 当前攻击月牙该用什么颜色。
##
## 抽成函数是为了让 _draw() 和测试用**同一个来源** —— 否则测试断言的是一套、
## 实际画出来的是另一套，"测过了"并不代表"看得对"。
func get_arc_color() -> Color:
	if _attack_left <= 0.0:
		return ARC_IDLE_COLOR
	return ELEMENT_COLORS.get(element, ARC_DEFAULT_COLOR)


## 按 L 循环切换附魔元素（火 → 水 → 火 …）
##
## 用户 2026-10-06 晚的设计。用取模在 ELEMENTS 里循环，
## 所以将来"每关自选 3 种元素"只是换数组内容，这个函数一行都不用改。
func _handle_element_switch(delta: float) -> void:
	_switch_cd = maxf(_switch_cd - delta, 0.0)
	_switch_flash = maxf(_switch_flash - delta, 0.0)

	if not Input.is_action_just_pressed("switch_element") or _switch_cd > 0.0:
		return

	element_index = (element_index + 1) % ELEMENTS.size()
	element = ELEMENTS[element_index]
	_switch_cd = ELEMENT_SWITCH_CD
	_switch_flash = SWITCH_FLASH_TIME
	# 若切换正好发生在攻击窗口内，月牙要立刻换成新元素的颜色
	queue_redraw()
	element_changed.emit(element)


## 元素的"角色侧"视觉：切换瞬间闪一下**新元素**的颜色
##
## ⚠️ 注意攻击时角色**不染色** —— 攻击的元素表现挂在**月牙**上。
##    这两件事别搞混：切换闪光说的是"我现在是什么属性"，
##    月牙颜色说的是"这一刀是什么属性"。用户明确要求过元素表现在攻击范围上。
func _update_element_visual() -> void:
	if sprite == null:
		return
	if _switch_flash > 0.0:
		var c: Color = ELEMENT_COLORS.get(element, ARC_DEFAULT_COLOR)
		sprite.modulate = Color(c.r, c.g, c.b, 1.0)
	else:
		sprite.modulate = TINT_CLEAR


## 给 HUD 用：当前元素的显示名
func get_element_label() -> String:
	match element:
		ELEMENT_FIRE: return "火"
		ELEMENT_WATER: return "水"
		_: return element


## 被任何危险物（敌人、陷阱）碰到时由它们调用
## 死亡。
##
## ⚠️ 2026-10-08 起**敌人 / 危险物不该再直接调它** —— 它们改调 take_damage()，
##    由血量决定生死（血量归零才会走到这里）。
##    抖动也搬到了那两个入口（不同伤害档位抖得不一样），所以这里不再抖。
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
	# 清掉切换闪光，但**保留当前元素** —— 死一次不该逼玩家重新选属性
	_switch_flash = 0.0
	# 血量回满 + 清无敌帧/闪红。
	# ⚠️ **必须回满**：否则会出现"残血复活 → 一碰就死 → 死亡螺旋"；
	#    而且检查点复位本来就会重置敌人，两边状态一致才对得上。
	hp = MAX_HP
	_iframe = 0.0
	_hurt_flash = 0.0
	hp_changed.emit(hp, MAX_HP)
	# 兜底：万一抖动还没播完就复活了，别让相机歪着跟玩家跑
	_trauma = 0.0
	if camera:
		camera.offset = Vector2.ZERO


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


## 攻击范围的可视化：一道小月牙（斩击弧光）
##
## 用户 2026-10-06 的要求：攻击时"攻击范围变红"，并明确说用**小月牙的形状**来表现范围。
## 所以这里画的是弧，不是调试用的矩形框 —— 矩形只说明边界在哪，
## 而月牙本身就是"刀扫过去"的样子，它天然在表达"这一刀覆盖了哪片区域"。
##
## 历史教训（留着，别重犯）：这个绘制曾经朝右时从 y=0 起画、朝左时从 y=-17 起画，
## 于是框在两种朝向下位置差 34px（朝右看着"偏下/矮一截"）。
## 而**真实碰撞判定一直是对的**（AttackArea 在 position=(±33, 0)、形状 52x34）——
## 那个 bug 只骗眼睛。教训：可视化必须和真实判定共用同一个中心点。
## 月牙同样以玩家原点为中心、只按朝向水平翻转，两种朝向天然对称。
func _draw() -> void:
	draw_colored_polygon(_build_arc_polygon(), get_arc_color())


## 构造月牙多边形：外弧 + 内弧围成的封闭区域
##
## 两条弧共用**同一个圆心**（玩家原点），但内弧的两端把半径收向外半径，
## 于是两头自然收成尖角 —— 这才是"月牙"而不是"扇环"的关键。
func _build_arc_polygon() -> PackedVector2Array:
	var pts := PackedVector2Array()
	var half := deg_to_rad(ARC_SPAN_DEG) * 0.5
	# 朝右从 0 起算、朝左从 π 起算（Godot 里 y 轴向下，角度顺时针增长）
	var base := 0.0 if facing > 0 else PI

	# 外弧：-half -> +half
	for i in range(ARC_SEGMENTS + 1):
		var t := float(i) / float(ARC_SEGMENTS)
		var ang := base + lerpf(-half, half, t)
		pts.append(Vector2(cos(ang), sin(ang)) * ARC_OUTER_R)

	# 内弧：反向走回来（+half -> -half），半径在两端收向外半径，收出尖角
	for i in range(ARC_SEGMENTS + 1):
		var t := float(i) / float(ARC_SEGMENTS)
		var ang := base + lerpf(half, -half, t)
		var edge := absf(t - 0.5) * 2.0        # 中间 0、两端 1
		var r := lerpf(ARC_INNER_R, ARC_OUTER_R, pow(edge, ARC_TIP_SHARP))
		pts.append(Vector2(cos(ang), sin(ang)) * r)

	return pts
