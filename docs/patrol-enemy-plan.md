# 移动巡逻敌人 · 落地方案（Godot 4.7.2 实机验证）

> 本文所有结论都在你自己的机器上跑过：`Godot_v4.7.2-stable_win64_console.exe`（`4.7.2.stable.official.ed1daf0bf`）。
> 配套代码 [PatrolEnemy.gd](../scripts/PatrolEnemy.gd)、测试 [test_patrol.gd](../tests/test_patrol.gd)（**41 项全通过**）。
> 已验证过的重要 API 事实会标注「实测」。

---

## 0. 速查结论

| 你的问题 | 结论 |
|---|---|
| `CharacterBody2D` 还是静态体 + 手动移动？ | **`CharacterBody2D`**。唯一例外：要让玩家能站上去被带走 → `AnimatableBody2D` |
| 平台边缘检测用什么？ | 一条**朝下、放在前脚外侧的 `RayCast2D`**，每帧 `force_raycast_update()` |
| 视线检测用 `Area2D` 还是 `RayCast2D`？ | **首选 `RayCast2D`**。`Area2D` 没有遮挡概念（实测：隔着一堵墙照样"看到"玩家）。要"背后也能发现"就两个叠加：`Area2D` 粗筛 + `RayCast2D` 精筛 |
| 必须知道的坑 | **`Danger` 只靠 `body_entered` 会失效**：玩家复活到敌人身上时重叠状态没变化 → 信号不再发 → 隐形无敌（实测只判死 1 次）。改成每物理帧轮询 + 复活保护窗口 |

---

## 1. 最简单的巡逻敌人

### 1.1 为什么必须是 `CharacterBody2D`

继续用 `StaticBody2D` + 手动改 `position` 会有四个具体问题：

1. **穿墙**：手改 `position` 是「瞬移」。物理服务器只看到两个相距很远的离散位置，中间过程不存在。薄墙、玩家、判定区都可能被整帧跳过。
   `CharacterBody2D.move_and_slide()` 是**扫掠式**的：它按运动路径做形状检测。实测：一个 26×34 的 `CharacterBody2D` 以 **6000 px/s**（每物理帧 100px）撞 **20px 厚**的墙，30 帧后停在 `x = -23`，**没有穿过去**。
2. **没有 `is_on_floor()` / `is_on_wall()`**：巡逻掉头、"前方没路"全靠这两个状态。`StaticBody2D` 完全没有，你得自己写射线模拟。
3. **语义与性能都不对**：`StaticBody2D` 的定位是「不动的世界几何」，它的 broadphase 条目按静态优化。每帧移动它会反复更新 AABB。
4. **没有未来**：跳跃巡逻、斜坡行走、被击退、被击飞——`CharacterBody2D` 全都现成；`StaticBody2D` 每一条都要手写。

**唯一应该换的场合**：如果你想让玩家能「站在敌人头上被带着走」，那属于**移动平台**，应该用 `AnimatableBody2D`（实测 `sync_to_physics` 默认为 `true`，会正确携带站在上面的物体）。
但「一击必杀」的游戏里玩家不该能踩在敌人身上，所以这里 `CharacterBody2D` 是对的。

### 1.2 节点结构与物理层

```
Enemy2 (CharacterBody2D)        ← 脚本挂这里（和 Enemy1 的"脚本挂父节点"约定一致）
├── Shape      (CollisionShape2D)  身体；玩家的 AttackArea 检测到它就算被砍中
├── Visual     (ColorRect)         色块占位
├── LedgeProbe (RayCast2D)         朝下前方探测脚下有没有地
├── Sight      (RayCast2D)         视线
└── Danger     (Area2D)            罩住玩家即判死
    └── Shape  (CollisionShape2D)
```

物理层数值（**本项目用的是「位值」，不是层号**，见坑 1）：

| 节点 | `collision_layer` | `collision_mask` | 含义 |
|---|---|---|---|
| `Enemy2` (CharacterBody2D) | `4` | `1` | 属于第 3 层 enemy；只与世界碰撞 |
| `LedgeProbe` | `0` | `1` | 只看世界 |
| `Sight` | `0` | `3` | 世界 + 玩家（**必须含世界层**才能判断遮挡） |
| `Danger` | `0` | `2` | 只检测第 2 层 player |

> 敌人 `mask = 1`（不含玩家层）是刻意的：这样敌人不会被玩家推动、不会被玩家卡住，行为可预测。
> 代价是**玩家能穿过敌人身体**（实测：玩家从 `x=-120` 一路跑到 `x=128` 穿过站在 `x=60` 的敌人），
> 全靠 `Danger` 判死 —— 这正是《武士刀零》要的手感（碰一下就死，不需要推挤）。

### 1.3 完整实现

完整带注释的代码在 **[scripts/PatrolEnemy.gd](../scripts/PatrolEnemy.gd)**（468 行，含调试可视化和自动补节点）。
关键段落：

- 物理层设置：[:121-131](../scripts/PatrolEnemy.gd#L121-L131)
- 探针自动配置（用 `Shape` 的实际尺寸算位置，不用手工同步数字）：[:161-183](../scripts/PatrolEnemy.gd#L161-L183)
- 状态机（巡逻/掉头停顿/原地待命/追击）：[:216-242](../scripts/PatrolEnemy.gd#L216-L242)
- 边缘 + 墙体检测：[:265-293](../scripts/PatrolEnemy.gd#L265-L293)
- 视线检测：[:296-320](../scripts/PatrolEnemy.gd#L296-L320)
- 一击必杀 + 轮询判死：[:353-408](../scripts/PatrolEnemy.gd#L353-L408)

**极简版**（30 行，先跑起来再考虑追击）：

```gdscript
extends CharacterBody2D
## 极简巡逻兵：两个 x 之间来回走 + 前方脚下有地检测
## 危险区照抄现有 Enemy1 的 Danger 子节点（Area2D, collision_mask = 2）即可

@export var left_x := -96.0    ## 巡逻左边界（相对出生点）
@export var right_x := 96.0    ## 巡逻右边界（相对出生点）
@export var speed := 70.0
@export var gravity := 1500.0  ## ⚠️ 和 Player.gd 的 GRAVITY 保持一致

var _dir := 1
var _l := 0.0
var _r := 0.0
@onready var probe: RayCast2D = $LedgeProbe

func _ready() -> void:
	add_to_group("enemy")
	collision_layer = 0
	set_collision_layer_value(3, true)   # 第 3 层 = enemy（按【层号】，不是位值 4）
	collision_mask = 0
	set_collision_mask_value(1, true)    # 只和世界碰撞
	_l = global_position.x + left_x
	_r = global_position.x + right_x
	probe.position = Vector2(15.0, 15.0)         # 脚底前外侧，按自己身体尺寸调
	probe.target_position = Vector2(0.0, 14.0)   # 朝下探 14px
	probe.collision_mask = 0
	probe.set_collision_mask_value(1, true)

func _physics_process(delta: float) -> void:
	if not is_on_floor():
		velocity.y = minf(velocity.y + gravity * delta, 900.0)
	# 朝向变了，探针要跟着换边（否则往回走时会用错侧的探测结果）
	probe.position.x = 15.0 * float(_dir)
	# 到边界 / 前方脚下没地 / 撞墙 -> 掉头
	probe.force_raycast_update()
	var at_edge := (global_position.x >= _r and _dir > 0) or (global_position.x <= _l and _dir < 0)
	if at_edge or not probe.is_colliding() or is_on_wall():
		_dir = -_dir
	velocity.x = speed * float(_dir)
	move_and_slide()
```

> `is_on_wall()` 在 `move_and_slide()` **之后**才更新。极简版在移动前判断，用的是上一帧结果——最多晚一帧掉头，
> 能接受；完整版（`PatrolEnemy.gd`）把它放在移动之后，更准。

**完整版的核心状态机**（可直接抄，其余同上）：

```gdscript
enum State { PATROL, TURN_PAUSE, IDLE, CHASE }

func _physics_process(delta: float) -> void:
	if _dead:
		return
	_update_sight(delta)   # 视线（第 3 节）
	_think(delta)          # 决策：这一帧往哪走
	_move(delta)           # 施加速度 + move_and_slide
	_poll_danger()         # 每帧轮询危险区（坑 2 的对策）
	queue_redraw()         # 调试可视化

func _think(delta: float) -> void:
	match _state:
		State.PATROL:
			_move_dir = _facing
			# ① 到达巡逻边界 -> 掉头
			if (_facing > 0 and global_position.x >= _right_x) \
					or (_facing < 0 and global_position.x <= _left_x):
				_start_turn()
			# ② 前方脚下没地 -> 掉头（"走到平台边缘停下来"）
			elif _no_ground_ahead(_facing):
				_start_turn()

		State.TURN_PAUSE:                 # 掉头时的停顿，顺带给玩家反应时间
			_move_dir = 0
			_turn_timer -= delta
			if _turn_timer <= 0.0:
				_state = State.PATROL

		State.IDLE:                       # 两侧都没地（窄柱子）：站住别抽筋
			_move_dir = 0
			if not _no_ground_ahead(_facing):
				_state = State.TURN_PAUSE
				_turn_timer = turn_pause

		State.CHASE:
			_think_chase()

func _move(delta: float) -> void:
	if not is_on_floor():
		velocity.y = minf(velocity.y + gravity * delta, max_fall_speed)
	elif velocity.y > 0.0:
		velocity.y = 0.0

	velocity.x = float(_move_dir) * (chase_speed if _state == State.CHASE else patrol_speed)
	move_and_slide()
	_sync_visual()

	# 撞墙 -> 掉头。is_on_wall() 只在"刚被墙挡住"时为真，所以必须在移动之后判断
	if _state == State.PATROL and _move_dir != 0 and is_on_wall():
		_start_turn()

func _start_turn() -> void:
	_facing = -_facing
	_move_dir = 0
	_turn_timer = turn_pause
	_state = State.TURN_PAUSE
	# 新方向前方也没地面 -> 干脆站住（否则会在两根崖边之间来回抽筋）
	if _no_ground_ahead(_facing):
		_state = State.IDLE
```

### 1.4 已经接进你的关卡

[main.tscn](../main.tscn) 里**新增**了 `Enemies/Enemy2`（`CharacterBody2D` + `PatrolEnemy.gd` + `Shape/Visual/LedgeProbe/Sight/Danger` 五个子节点），
巡逻 ±55px、`can_chase = true`。原有 `Enemy1` 一个字段都没动。

> **协同提示**：另有并行任务在调整平台高度（`PlatformA` 已从 `y=380` 移到 `y=440`，`PlatformB` 移到 `395`），
> 它同时把 `Enemy2` 的 y 从 `352` 同步到了 `412`（= 平台顶部 429 − 半身 17）。
> 这是正确做法：**平台高度一变，站在上面的敌人 y 必须跟着改**，或者靠重力让它自己落下去
> （`_no_ground_ahead` 在空中返回真 → 进 `IDLE` 站住，但重力照常作用，落地后自动恢复巡逻，能自愈，只是开局会掉一下）。

**实机复验**（平台位置被改动之后跑的场景内检查）：

```
Enemy2 子节点 = ["Shape", "Visual", "LedgeProbe", "Sight", "Danger"]
初始位置 = (400.0, 412.0)
300 帧 x 范围 = 344.0 ... 456.0        y = 411.9
is_on_floor = true  掉下去了 = false  状态 = PATROL
```

**玩家攻击它**（把玩家挪到旁边按 J）：

```
敌人数量 = 2
把玩家挪到旁边按 J 攻击 -> 敌人数量 2 -> 1，击杀数 = 1
```

---

## 2. 地面检测（走到平台边缘停下来/掉头）

### 2.1 推荐方案：向下的 `RayCast2D`

放在**前脚外侧**（`x = 半身宽 + 2`），`target_position = (0, 探测深度)`，只对世界层生效：

```gdscript
## 指定方向的前方脚下有没有地面
func _no_ground_ahead(dir: int) -> bool:
	if _ledge_probe == null:
		return false
	_ledge_probe.position.x = _probe_forward * float(dir)   # 探针跟着朝向换边
	_ledge_probe.force_raycast_update()                     # ★ 关键
	return not _ledge_probe.is_colliding()
```

**为什么要 `force_raycast_update()`**：`RayCast2D` 默认只在物理帧的固定时机刷新。敌人正在移动时，
直接读 `is_colliding()` 可能拿到**上一帧位置**的结果，在边缘上会差一两像素，表现为「偶尔多走半步」。
强制刷新一次，代价极小（一条射线）。

**探测深度（`ledge_probe_depth`）怎么定**：它是「多大的台阶/缝隙算没路」。
- 默认 `14`：能容忍小坑和小台阶（不会因为地面上一个 2px 的接缝就掉头）。
- 平台边缘是直角时，`10~16` 都工作良好。
- 调太大会出现「明明到崖边了还往前迈」；调太小会在瓦片地形上误判。

**实测**（`test_patrol.gd` ②）：平台宽 200（半宽 100），巡逻范围设 ±500（远超平台）——
敌人最远只走到 `x = 85`（= 100 − 15 探针前伸），**没有掉下去**，且两侧都走到了边缘（`min_x = -85`）。
说明边缘检测既没漏也没过度保守。

### 2.2 必须处理的三个边界情况

| 情况 | 现象 | 处理（`PatrolEnemy.gd` 里的做法） |
|---|---|---|
| 站在比身体还窄的柱子上 | 两侧都没地 → 掉头后立刻又没地 → **每 `turn_pause` 秒抽一次筋** | 新方向前方也没地就进 `IDLE` 站住，每帧重试直到有地 [:332-342](../scripts/PatrolEnemy.gd#L332-L342)。实测：90 帧位移 **0.00 px**，状态 `IDLE` |
| 到达巡逻边界 | 一直撞边界抖动 | 边界 + 掉头**停顿** `turn_pause = 0.25s`（停顿还顺便给了玩家反应时间） |
| 撞墙 | 贴着墙原地推 | `is_on_wall()`（在 `move_and_slide()` 之后判断）→ 掉头。实测：墙左边缘 140、半身 13，`max_x = 127.0` 精确停住，之后往回走 |

### 2.3 备选：不加节点的 `test_move()`

不想多一个 `RayCast2D` 节点时，`CharacterBody2D.test_move()` 可以直接问「从这个位置移动这个向量会不会撞到东西」：

```gdscript
# 把探针位置当成"从前方脚下再往下探一段"，不撞 = 前方没地
var from := global_transform.translated(Vector2(_probe_forward * _facing, _body_size.y * 0.5 - 2.0))
var has_ground := test_move(from, Vector2(0.0, ledge_probe_depth))
```

优点：不用节点、不用 `force_raycast_update`（每次都实时算）。缺点：编辑器里看不见、调试不方便，
而且它用的是**整个身体形状**，不如一条细射线精确。**我推荐射线**（可视化调试的价值很大）。

### 2.4 不推荐：用 `Area2D` 探地面

- 重叠状态每物理帧才更新一次，边缘上有一帧延迟；
- 敌人贴边时容易在「有/无」之间抖动，需要额外加迟滞；
- 开销比一条射线大；
- 你依然要自己判断「是哪一侧、算不算地面」。

---

## 3. 玩家检测：`Area2D` vs `RayCast2D`

### 3.1 结论：2D 平台游戏首选 `RayCast2D`

| | `Area2D`（感知半径） | `RayCast2D`（视线） |
|---|---|---|
| 判断「有没有遮挡」 | **不能**。隔墙也会发现玩家 | 天然可以（第一命中是墙 = 被挡住） |
| 判断「在不在前方」 | 需要拼扇形/多个区域 | 一条射线搞定（`target_position` 跟朝向） |
| 体积感（大范围感知） | 好 | 差（只有一条线，玩家跳起来就丢了） |
| 开销 | 常驻维护重叠列表 | 每帧一次射线 |
| 适合的用途 | 粗筛「附近有没有人」 | 精筛「能不能真的看见」 |

**实测证据**（`test_patrol.gd` ⑰）：同一个位置，隔着一堵墙放一个 `Area2D`（mask=2）和一条 `RayCast2D`（mask=1|2）：

```
✓ Area2D 感知区隔着一堵墙也检测到玩家（重叠 1 个）—— 它没有「遮挡」概念
✓ 同一位置的 RayCast2D 视线被墙挡住 -> 不追击（状态 PATROL）
```

### 3.2 最小实现（单射线，只看向前方）

```gdscript
func _update_sight(delta: float) -> void:
	if not can_chase or _sight == null:
		return
	_sight.target_position = Vector2(sight_distance * float(_facing), 0.0)  # 跟着朝向
	_sight.force_raycast_update()

	var seen_now := false
	if _sight.is_colliding():
		var hit := _sight.get_collider()
		# 第一命中就是玩家 = 看得见；第一命中是墙 = 被挡住（自动排除）
		if hit is Node2D and _is_in_group_upwards(hit, GROUP_PLAYER):
			_seen_player = hit as Node2D
			seen_now = true

	if seen_now:
		_lost_timer = lose_sight_time       # 刷新"还追多久"
		if _state != State.CHASE:
			_state = State.CHASE
	elif _state == State.CHASE:
		_lost_timer -= delta
		if _lost_timer <= 0.0:
			_end_chase()                    # 追丢后愣一下再回巡逻
```

要点：
- `collision_mask` 必须**同时含世界层和玩家层**（本项目 `1|2 = 3`），否则射线会穿过墙命中玩家。
- `get_collider()` 返回的是**碰撞体本身**。你的玩家根节点就是 `CharacterBody2D`，所以直接就是它；
  但为了以后加了子 `Hitbox`/`Area2D` 也不坏，仍然用「向上找组」的写法。
- `hit_from_inside = false`：玩家贴在敌人身上时不会因为「射线起点在玩家内部」而误判。
- 单射线 = **只看前方**。玩家从背后接近不会被发现（这其实是好手感：可以背刺）。
  要「背后也能发现」就再加一个反方向的探针，或者按下面的组合方案。

### 3.3 组合方案（粗筛 + 精筛，敌人多的时候用）

```gdscript
## ① Area2D 粗筛：便宜地筛掉"根本不在附近"的玩家
func _player_in_sense_range() -> bool:
	return _sense_area.has_overlapping_bodies()   # _sense_area.mask = 2

## ② RayCast2D 精筛：确认视线没被地形挡住
func _has_line_of_sight(target: Node2D) -> bool:
	_sight.target_position = to_local(target.global_position)
	_sight.force_raycast_update()
	return _sight.is_colliding() and _is_in_group_upwards(_sight.get_collider(), GROUP_PLAYER)

func _update_sight(delta: float) -> void:
	if not _player_in_sense_range():
		# 不在感知范围内 -> 直接开始倒计时，不做射线
		...
		return
	# 在范围内：可以顺便 360° 检查（朝右、朝左两条射线，或者直接用视线向量）
	...
```

### 3.4 追击时别忘了边缘检测

**这是最容易漏的一条**：敌人为了追你，会直接从平台上走下去。

```gdscript
	# ⚠️ 追击时**必须**继续做边缘检测，否则敌人会为了追你跳下平台自尽
	if _no_ground_ahead(_move_dir):
		_move_dir = 0     # 刹在崖边（也可以改成掉头，看你要什么行为）
```

实测（`test_patrol.gd` ⑦）：平台半宽 100，玩家悬在平台外的空中 `x=300`——
敌人追到 `x = 86.2` 就刹住，`is_on_floor()` 仍为真，状态保持 `CHASE`（不会莫名放弃）。

---

## 4. 必须知道的坑（每条都有实测数据）

### 坑 1（配置级，最先踩）：层号 ≠ 位值，而且 `CharacterBody2D` 默认就在世界层

- 编辑器里勾的是「第 N 层」，`.tscn` 里存的是**位值**：第 3 层 = `1 << 2` = **4**。
  你 README 的表格用层号，`main.tscn` 里写 `collision_layer = 4` —— 说的是同一件事，别混。
  代码里推荐用 `set_collision_layer_value(层号, true)`（**层号从 1 开始**）。
- **但**：`CharacterBody2D` 新建时 `collision_layer = 1`（世界层）。如果你只写
  `set_collision_layer_value(3, true)`，结果是 `1 | 4 = 5` —— 敌人同时属于世界层，
  而玩家 `mask = 1`，于是**玩家会撞上一堵看不见的墙**（站在敌人旁边过不去）。
  实测复现：`layer = 5`。
  正确写法（[PatrolEnemy.gd:121-131](../scripts/PatrolEnemy.gd#L121-L131)）：

```gdscript
	collision_layer = 0                  # ★ 先清空默认的第 1 层
	set_collision_layer_value(3, true)   # 第 3 层 = enemy → 位值 4
	collision_mask = 0
	set_collision_mask_value(1, true)    # 只和世界碰撞
```

### 坑 2（本方案里最阴的）：`body_entered` 不会重发 → 隐形无敌

`Area2D.body_entered` 只在「重叠状态从无到有」的那一帧发一次。
玩家**复活到敌人身上**时，重叠状态从来没变化过 → 信号不再发 → 危险区等于失效。

实测（`test_patrol.gd` ⑫，只靠 `body_entered`）：

```
✓ 只靠 entered：站敌人身上 respawn 只判死 1 次，之后再也不触发（隐形无敌）
✓ 玩家此刻活着，而且就站在敌人身体里（危险区已失效）
```

**为什么移动敌人让它更致命**：静止敌人至少「离开再回来」能重新触发；移动敌人擦着你走过去，
entered/exited 的时机更难预测，你会看到「有时撞死、有时穿过」。

**对策（已在实现里）**：每物理帧轮询危险区，而不是只等信号：

```gdscript
func _poll_danger() -> void:
	if not danger_polling or _dead or _kill_pending:
		return
	if _danger == null or not is_instance_valid(_danger) or not _danger.monitoring:
		return                        # ⚠️ monitoring=false 时查询会报错，见坑 8
	for body in _danger.get_overlapping_bodies():
		if body is Node2D and _is_in_group_upwards(body, GROUP_PLAYER):
			_kill_pending = true
			_kill_player_deferred.call_deferred(body)   # 仍然 deferred，保证玩家攻击优先
			return
```

实测（⑭）：同样场景下 120 帧内判死 **118 次** —— 隐形无敌没了。
代价是每个敌人每帧一次列表查询（`Area2D` 内部本来就维护了这个列表，只是复制一份）。

### 坑 3：移动敌人占住检查点 → 死亡螺旋

`Main.gd` 目前在「玩家死亡后不重置敌人」（注释里写明了）。加了移动敌人之后，
只要检查点在巡逻路线上，玩家会**每秒死好几次**。

实测（`test_patrol.gd` ⑮）：敌人巡逻路线经过检查点，玩家复活后不动 ——
**400 帧内死了 82 次**（约每秒 12 次），游戏完全不可玩。

对策（两级）：

```gdscript
# PatrolEnemy.gd 已提供 set_danger_enabled(on) 和 reset_enemy()

# ① Main.gd 的复活流程：给一个"重生保护窗口"
func _do_respawn() -> void:
	player.respawn(checkpoint)
	for e in get_tree().get_nodes_in_group("enemy"):
		if e.has_method("set_danger_enabled"):
			e.set_danger_enabled(false)                      # 立刻关掉危险区
			get_tree().create_timer(0.35).timeout.connect(   # 0.35 秒后打开
				func() -> void:
					if is_instance_valid(e):
						e.set_danger_enabled(true)
			)

# ② 需要"回到干净开局"时（比如整段重试）：让敌人回位
	for e in get_tree().get_nodes_in_group("enemy"):
		if e.has_method("reset_enemy"):
			e.reset_enemy()
```

实测：保护窗口内死亡 **0 次**；`reset_enemy()` + 复活到安全点后 120 帧内 **0 次**。
（更彻底的做法是给 `Player.gd` 加 0.3~0.5 秒无敌帧，那是你的设计选择。）

### 坑 4：Tunneling 的真相 —— 别把两件事混起来

- **`CharacterBody2D` 撞地形不会穿**（扫掠式，见 1.1 实测：6000 px/s vs 20px 墙）。
- **真正会漏的是 `Area2D` 的离散重叠检测**：它每物理帧采样一次位置。
  如果「玩家 + 敌人」一帧内的相对位移大于危险区宽度，就可能整帧跨过去 → 不触发。

**量化规则**（用它检查你自己的判定框尺寸）：

```
危险区宽度 ≥ (玩家最大速度 + 敌人最大速度) / 物理帧率 + 安全余量
```

你当前的数据：冲刺 620 + 追击 110 = 730 px/s，`730 / 60 ≈ 12.2 px/帧`；
`Danger` 是 `body + 4 = 30px` 宽 → 余量 2.5 倍，**安全**。
实测（⑯）：冲刺单帧位移 **10.3 px**（正常）与 **10.4 px**（`time_scale = 0.35` 的子弹时间下）——
**子弹时间不会放大单帧位移**，所以不需要为慢动作加宽判定框。
（原因：`time_scale` 同时缩小 `delta`，而玩家的速度补偿按 `1/time_scale` 放大，两者抵消。）

### 坑 5：同帧互杀（玩家砍中的同一帧被敌人撞死）

你的 `Enemy.gd` 已经用 `call_deferred` 处理了，**这套机制在移动敌人上依然有效**（实测时序，逐帧跟踪）：

```
帧 | 玩家x  敌人x | 玩家死亡 敌人死亡 | 攻击框 危险区 | 攻框重叠 危险区重叠
 6 |  411.0  443.2 | false  false  | false  true   | 0 0
 7 |  411.0  441.3 | false  false  | false  true   | 0 0
 8 |  411.0  439.5 | false  true   | true   true   | 1 0     ← 攻击框开启并命中：敌人死，危险区同帧关闭
 9 |  411.0  439.5 | false  true   | true   false  | 0 0     ← 玩家安然无恙
```

**但**：如果敌人在玩家攻击生效**前一帧**就贴上了玩家，玩家会先死（公平：物理上它先碰到你）。
`just_pressed` 需要 2 帧才为真，所以「敌人贴脸时再按攻击」经常来不及 —— 这是设计层面的事
（要么给攻击更早的判定帧，要么靠冲刺拉开距离）。

### 坑 6：敌人死后尸体继续滑行

移动敌人被 `kill()` 后必须立刻停住，否则它会带着 `velocity` 继续滑出去、甚至滑出屏幕：

```gdscript
	_dead = true
	velocity = Vector2.ZERO
	_move_dir = 0
	set_physics_process(false)     # ★ 移动敌人必做
```

### 坑 7：`queue_free()` 之后访问引用会崩

敌人死亡有 tween 淡出（0.18 秒后才 `queue_free`），这期间别的脚本可能还在引用它。实测崩溃信息：

```
Invalid access to property or key 'global_position' on a base object of type 'previously freed'
```

规则：任何跨帧保存的节点引用（追踪目标、当前敌人、`Danger` 里的 body）用之前都要
`is_instance_valid(x)` 检查（[PatrolEnemy.gd:245-249](../scripts/PatrolEnemy.gd#L245-L249)、[:389-397](../scripts/PatrolEnemy.gd#L389-L397)）。

### 坑 8：`monitoring == false` 时不能查询重叠

实测报错：

```
ERROR: Can't find overlapping bodies when monitoring is off.  (area_2d.cpp:465)
```

所以轮询前必须先判 `_danger.monitoring`（[PatrolEnemy.gd:205](../scripts/PatrolEnemy.gd#L205)），
而且 `set_danger_enabled(false)` 之后本轮询自然就停了 —— 这正好和「重生保护窗口」配合。
另外，**在物理回调中直接改 `monitoring` 可能被引擎拒绝**，一律用 `set_deferred("monitoring", ...)`。

### 坑 9：重力常数别混用

`CharacterBody2D.get_gravity()` 实测**存在**（4.3+），但它返回的是项目设置
`physics/2d/default_gravity = 980`（你的项目没改这个值），
而 `Player.gd` 自己用的是 `GRAVITY = 1500`。
如果敌人用 `get_gravity()`、玩家用 1500，两者下落节奏会不一样，跳台时机的手感会明显错位。
`PatrolEnemy.gd` 因此用 `@export var gravity := 1500.0` 并注释「必须和 Player.gd 一致」。
（另一个实测细节：节点**没进场景树**时调用 `get_gravity()` 会报 `Parameter "state" is null` 并返回 `(0,0)`。）

### 坑 10：`ShapeCast2D` 的属性名（顺手纠正一个常见笔误）

实测 4.7.2：`ShapeCast2D` 有 `get_collision_count()`，**没有** `collision_result_count`
（那是旧文档里的名字）。如果你以后要做「扫掠式攻击判定」，用 `get_collision_count()`。

---

## 5. 怎么验证 / 怎么撤销

```powershell
$g = '<Godot console 可执行文件>'
$p = '<项目目录>'
& $g --headless --path $p --script tests/test_patrol.gd      # 期望 PATROL_OK 通过 41 项
& $g --headless --path $p --script tests/test_core.gd        # 期望 CORE_OK 通过 7 项（未受影响）
& $g --headless --path $p --script tests/test_slowmo.gd      # 期望 SLOW_OK 通过 12 项（未受影响）
```

`test_patrol.gd` 覆盖：层设置、巡逻往返、边缘检测、窄柱子待命、撞墙掉头、视线追击、
隔墙不发现、追击刹在崖边、砍死移动中的敌人、移动敌人撞死玩家、高速不穿墙、
玩家穿过敌人、隐形无敌（两种模式对比）、死亡螺旋与对策、子弹时间单帧位移、Area2D 隔墙可见。

**本次新增/改动的文件**
- 新增 `scripts/PatrolEnemy.gd`
- 新增 `tests/test_patrol.gd`
- 修改 `main.tscn`：`load_steps` 10 → 11，加一条 `ext_resource`，新增 `Enemies/Enemy2` 节点树（**没有改动任何现有节点**）

> 同一个 `main.tscn` 还有另一个并行任务在调整平台高度（`PlatformA` `380 → 440`、`PlatformB` `300 → 395`）。
> 那是它的改动，不是我的；两边已经融合好（它同步了 `Enemy2` 的 y）。
> 它自己的 `tests/test_reachability.gd` 当时处于在建状态（失败 2 项），与本方案无关。

**撤销**：删掉上面两个新文件，并把 `main.tscn` 里的 `Enemy2` 节点树和那条 `ext_resource` 删掉即可。

---

## 6. 我不确定的地方

1. **`Area2D` 重叠状态的内部更新时机**我只做了行为层面的实测（「最迟下一帧能被 `get_overlapping_bodies()` 看到」），
   没有读 4.7 的引擎源码确认。
2. **没测过 4.6/4.7 的 2D 物理插值（physics interpolation）** 与判定/视线的相互影响。
   如果你在项目设置里开了插值，建议单独回归一次判定。
3. **没做性能实测**（几十个巡逻敌人同屏时的开销）。轮询 + 射线都是常数级开销，但数量级我没量过。
4. **美术/动画层面没验证**：现在是 `ColorRect` 色块。换成 `AnimatedSprite2D` 后
   `Visual.scale.x = -1` 的翻转写法要相应改成 `AnimatedSprite2D.flip_h`。
5. 4.7 是否还有我不知道的新增物理 API（比如更省事的平台/巡逻辅助），**我没查 4.7 的完整变更日志**，
   本文只使用了实测存在且行为符合预期的 API。
