extends SceneTree
## 像素 sprite 生成器 —— 把「文字画」转成 PNG sprite sheet
##
## 为什么走这条路：
##   项目里全是代码画的纯色方块，看不出动作。但装 PIL / 找素材包都要额外成本，
##   而 Godot 自带 Image API，可以直接生成 PNG —— 零依赖、今天就能见效。
##
## 怎么改：
##   下面每帧都是 16x16 的「文字画」，一个字符 = 一个像素：
##     .  透明      K  轮廓/头发    S  皮肤     C  衣服（外套）
##     W  白/围裙   B  靴子/腰带    G  武器/剑    E  眼睛
##   想改哪里，直接改文字。想加帧，复制一个字符串数组。
##
## 用法：Godot --headless --path <项目> --script tools/gen_sprites.gd

const CELL := 16          ## 单帧画布大小
const OUT_DIR := "res://art"

# ─────────────────────────── 调色板 ───────────────────────────
# 参考《武士刀零》的冷调：深蓝外套 + 白发 + 亮色刀
const PALETTE := {
	".": Color(0, 0, 0, 0),            # 透明
	"K": Color("1b2436"),              # 轮廓 / 头发（深蓝黑）
	"k": Color("2e3d5c"),              # 轮廓浅色 / 头发高光
	"S": Color("f0c9a0"),              # 皮肤
	"C": Color("3a5a8c"),              # 外套主色
	"c": Color("527bb5"),              # 外套亮部
	"W": Color("e8eef7"),              # 白（围裙 / 内衬）
	"B": Color("243044"),              # 靴子 / 腰带
	"G": Color("9fd3ff"),              # 刀光 / 武器
	"g": Color("6a9fd8"),              # 武器暗部
	"E": Color("2b3a55"),              # 眼睛
	"R": Color("d84a4a"),              # 敌人主色（红）
	"r": Color("8c2f2f"),              # 敌人暗部
}

# ─────────────────────────── 玩家：待机 2 帧 ───────────────────────────
const PLAYER_IDLE_0 := [
	"................",
	"......KKKK......",
	".....KkkkkK.....",
	"....KkSSSSkK....",
	"....KkSESESk....",
	"....KkSSSSSk....",
	".....KkSSSk.....",
	"......KccK......",
	".....KcCCcK...G.",
	"....KcCCCCcK..G.",
	"....KCWWWWCK.G..",
	"....KCWWWWCK....",
	"....KBBBBBBK....",
	"....KBB..BBK....",
	"...KBBK..KBBK...",
	"................",
]

const PLAYER_IDLE_1 := [
	"................",
	"......KKKK......",
	".....KkkkkK.....",
	"....KkSSSSkK....",
	"....KkSESESk....",
	"....KkSSSSSk....",
	".....KkSSSk.....",
	"......KccK......",
	".....KcCCcK...G.",
	"....KcCCCCcK..G.",
	"....KCWWWWCK.G..",
	"....KCWWWWCK....",
	"....KBBBBBBK....",
	"....KBB..BBK....",
	"...KBBK..KBBK...",
	"................",
]

# ─────────────────────────── 玩家：跑动 4 帧 ───────────────────────────
const PLAYER_RUN_0 := [
	"................",
	"......KKKK......",
	".....KkkkkK.....",
	"....KkSSSSkK....",
	"....KkSESESk....",
	"....KkSSSSSk....",
	".....KkSSSk.....",
	"......KccK......",
	"...G.KcCCcK.....",
	"...G.KcCCCCcK...",
	"....KCWWWWCK....",
	"....KCWWWWCK....",
	"....KBBBBBBK....",
	"...KBBK.KBBK....",
	"..KBBK...KBK....",
	"................",
]

const PLAYER_RUN_1 := [
	"................",
	"......KKKK......",
	".....KkkkkK.....",
	"....KkSSSSkK....",
	"....KkSESESk....",
	"....KkSSSSSk....",
	".....KkSSSk.....",
	"......KccK......",
	"...G.KcCCcK.....",
	"...G.KcCCCCcK...",
	"....KCWWWWCK....",
	"....KCWWWWCK....",
	"....KBBBBBBK....",
	".....KBBBBK.....",
	".....KBBBBK.....",
	"................",
]

const PLAYER_RUN_2 := [
	"................",
	"......KKKK......",
	".....KkkkkK.....",
	"....KkSSSSkK....",
	"....KkSESESk....",
	"....KkSSSSSk....",
	".....KkSSSk.....",
	"......KccK......",
	"...G.KcCCcK.....",
	"...G.KcCCCCcK...",
	"....KCWWWWCK....",
	"....KCWWWWCK....",
	"....KBBBBBBK....",
	"...KBBK.KBBK....",
	"...KBK...KBBK...",
	"................",
]

const PLAYER_RUN_3 := [
	"................",
	"......KKKK......",
	".....KkkkkK.....",
	"....KkSSSSkK....",
	"....KkSESESk....",
	"....KkSSSSSk....",
	".....KkSSSk.....",
	"......KccK......",
	"...G.KcCCcK.....",
	"...G.KcCCCCcK...",
	"....KCWWWWCK....",
	"....KCWWWWCK....",
	"....KBBBBBBK....",
	"....KBBBBK......",
	"...KBBK.KBBK....",
	"................",
]

# ─────────────────────────── 玩家：跳跃 / 下落 ───────────────────────────
const PLAYER_JUMP := [
	"................",
	"......KKKK......",
	".....KkkkkK.....",
	"....KkSSSSkK....",
	"....KkSESESk....",
	"....KkSSSSSk....",
	".....KkSSSk.....",
	"...G..KccK......",
	"...G.KcCCcK.....",
	"...G.KcCCCCcK...",
	"....KCWWWWCK....",
	"....KCWWWWCK....",
	"...KBBBBBBBK....",
	"..KBBK...KBBK...",
	"..KBK......KBK..",
	"................",
]

const PLAYER_FALL := [
	"................",
	"......KKKK......",
	".....KkkkkK.....",
	"....KkSSSSkK....",
	"....KkSESESk....",
	"....KkSSSSSk....",
	".....KkSSSk.....",
	"...G..KccK......",
	"...G.KcCCcK.....",
	"...G.KcCCCCcK...",
	"....KCWWWWCK....",
	"....KCWWWWCK....",
	"....KBBBBBBK....",
	"...KBBK.KBBK....",
	"..KBBK....KBBK..",
	"................",
]

# ─────────────────────────── 玩家：攻击（挥刀 2 帧）───────────────────────────
const PLAYER_ATTACK_0 := [
	"................",
	"......KKKK......",
	".....KkkkkK.....",
	"....KkSSSSkK....",
	"....KkSESESk....",
	"....KkSSSSSk....",
	".....KkSSSk..G..",
	"......KccK...G..",
	".....KcCCcK..G..",
	"....KcCCCCcKG...",
	"....KCWWWWCK....",
	"....KCWWWWCK....",
	"....KBBBBBBK....",
	"....KBB..BBK....",
	"...KBBK..KBBK...",
	"................",
]

const PLAYER_ATTACK_1 := [
	"................",
	"......KKKK......",
	".....KkkkkK.....",
	"....KkSSSSkK....",
	"....KkSESESk....",
	"....KkSSSSSk....",
	".....KkSSSk.....",
	"......KccK......",
	".....KcCCcK.....",
	"....KcCCCCcKGGGG",
	"....KCWWWWCK....",
	"....KCWWWWCK....",
	"....KBBBBBBK....",
	"....KBB..BBK....",
	"...KBBK..KBBK...",
	"................",
]

# ─────────────────────────── 敌人：巡逻 2 帧 ───────────────────────────
const ENEMY_0 := [
	"................",
	"................",
	".....RRRRRR.....",
	"....RrrrrrrR....",
	"....RrEEEERr....",
	"....RrrrrrrR....",
	"....RRRRRRRR....",
	"...RRRRRRRRRR...",
	"...RRrRRRRrRR...",
	"...RRrRRRRrRR...",
	"...RRRRRRRRRR...",
	"....RRRRRRRR....",
	"....rrr..rrr....",
	"...rrr....rrr...",
	"................",
	"................",
]

const ENEMY_1 := [
	"................",
	"................",
	".....RRRRRR.....",
	"....RrrrrrrR....",
	"....RrEEEERr....",
	"....RrrrrrrR....",
	"....RRRRRRRR....",
	"...RRRRRRRRRR...",
	"...RRrRRRRrRR...",
	"...RRrRRRRrRR...",
	"...RRRRRRRRRR...",
	"....RRRRRRRR....",
	"....rrr..rrr....",
	"....rrr..rrr....",
	"...rrr....rrr...",
	"................",
]


func _initialize() -> void:
	_run.call_deferred()


## 把一帧「文字画」写进目标图片的指定格子
func _blit(img: Image, lines: Array, col: int, row: int) -> void:
	for y in range(mini(lines.size(), CELL)):
		var line: String = lines[y]
		for x in range(mini(line.length(), CELL)):
			var ch := line[x]
			var color: Color = PALETTE.get(ch, PALETTE["."])
			if color.a <= 0.0:
				continue
			img.set_pixel(col * CELL + x, row * CELL + y, color)


func _make_sheet(frames: Array, cols: int, fname: String) -> void:
	var rows := int(ceil(float(frames.size()) / float(cols)))
	var img := Image.create(cols * CELL, rows * CELL, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	for i in range(frames.size()):
		_blit(img, frames[i], i % cols, i / cols)
	var path := OUT_DIR + "/" + fname
	var err := img.save_png(path)
	if err == OK:
		push_error("GEN_OK %s  (%dx%d, %d 帧)" % [fname, img.get_width(), img.get_height(), frames.size()])
	else:
		push_error("GEN_FAIL %s err=%d" % [fname, err])


func _run() -> void:
	# 确保输出目录存在
	var abs_dir := ProjectSettings.globalize_path(OUT_DIR)
	var da := DirAccess.open("res://")
	if not da.dir_exists("art"):
		da.make_dir("art")
		push_error("创建目录 " + OUT_DIR)

	push_error("=== 生成像素 sprite ===")
	_make_sheet([
		PLAYER_IDLE_0, PLAYER_IDLE_1,
		PLAYER_RUN_0, PLAYER_RUN_1, PLAYER_RUN_2, PLAYER_RUN_3,
		PLAYER_JUMP, PLAYER_FALL,
		PLAYER_ATTACK_0, PLAYER_ATTACK_1,
	], 5, "player_sheet.png")

	_make_sheet([ENEMY_0, ENEMY_1], 2, "enemy_sheet.png")

	push_error("=== 完成，输出到 " + abs_dir + " ===")
	quit(0)
