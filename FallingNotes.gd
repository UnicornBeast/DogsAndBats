extends Control

# ---------- Types ----------
class NoteInfo:
	var node: TextureRect
	var lane: int
	var beat: float

# ---------- Inspector: Textures ----------
@export var left_tex:  Texture2D
@export var down_tex:  Texture2D
@export var up_tex:    Texture2D
@export var right_tex: Texture2D
@export var note_scale: float = 1.0
@export var receptor_alpha: float = 0.45

# ---------- Inspector: Layout / Timing ----------
@export var lane_spacing: float = 100.0
@export var bpm: float = 120.0
@export var song_offset_ms: float = 0.0
@export var spawn_lookahead_sec: float = 1.2
@export var note_speed_px_s: float = 420.0
@export var timing_line_y_factor: float = 0.80
@export var timing_window_px: float = 40.0

# Win/Lose
@export var target_score: int = 4600

# Countdown
@export var countdown_seconds: int = 3

# Optional AudioStreamPlayer child named "Song"
@onready var song: AudioStreamPlayer = $Song if has_node("Song") else null

# ---------- Lanes / State ----------
var lane_x: Array[float] = []                    # lane CENTER X positions
var timing_line_y: float = 0.0
var receptors: Array[TextureRect] = []

var notes_live: Array[NoteInfo] = []
var notes_pending: Array[NoteInfo] = []
var _lane_tex: Array[Texture2D] = []

# ---------- HUD ----------
var hud: CanvasLayer
var score_label: Label
var combo_label: Label
var result_label: Label
var countdown_label: Label

var score: int = 0
var combo: int = 0
var ended: bool = false

# Gameplay start control
var game_start_time: float = 0.0   # absolute engine time (seconds) when gameplay starts
var started: bool = false          # flips true exactly at GO

# ---------- Fixed chart ----------
# L=0, D=1, U=2, R=3 — “LL R U D D UD R”
const CHART_BEATS: Array = [
	[0.6,0], [2.0, 3], [3.0, 2], [4.5, 1], [5, 1], [6.1, 2], [6.1, 1], [8, 3],[9, 2], [10, 1],
	[10.5, 2], [11, 0], [11.5, 0], [12, 1], [12.5, 1], [13.5, 2], [14, 2], [14.5, 3], [15, 3], [15.5, 2],
	[16, 2], [16.5, 2], [17, 2], [18.5, 1], [19, 0], [19.5, 3], [20, 1], [20.5, 1], [21, 1], [21.5, 1],
	[31, 3], [31.5, 3], [32, 2], [33, 1], [34.5, 2], [35, 2], [36, 1], [36.7, 0], [38, 0], [38.5, 0],
	[38.8, 0], [39.7, 1], [40, 2], [40.5, 3], [42, 1], [42.5, 1], [43, 2], [43.5, 3], [44, 0], [44.5, 0],
	[46, 2], [46.5, 2], [47, 3], [47.5, 0], [48, 1], [48.5, 1], [49.5, 0], [50, 1], [50.5, 2], [51, 3],
	[52, 0], [53, 2], [54, 2]
]

# ---------- Small time helper ----------
func _now_sec() -> float:
	return float(Time.get_ticks_msec()) * 0.001

# ---------- Beat helpers ----------
func beat_to_seconds(beat: float) -> float:
	return (60.0 / bpm) * beat

func seconds_to_beat(t: float) -> float:
	return t * bpm / 60.0

# Timing source for notes/song
func _song_time_seconds() -> float:
	if song and song.playing:
		return song.get_playback_position() + (song_offset_ms / 1000.0)
	var t: float = _now_sec() - game_start_time
	if t < 0.0:
		t = 0.0
	return t + (song_offset_ms / 1000.0)

func _note_center_y(node: TextureRect) -> float:
	return node.position.y + node.size.y * 0.5

func _tex_size(tex: Texture2D) -> Vector2:
	return tex.get_size() if tex != null else Vector2(48, 48)

func _spawn_y_for_time_to_line(dt_to_line: float, note_h: float) -> float:
	var center_y_at_spawn: float = timing_line_y - (note_speed_px_s * dt_to_line)
	return center_y_at_spawn - note_h * 0.5

# ---------- Setup ----------
func _ready() -> void:
	# Lane textures (L, D, U, R)
	_lane_tex = [left_tex, down_tex, up_tex, right_tex]
	for i in range(_lane_tex.size()):
		if _lane_tex[i] == null:
			push_warning("Lane %d has no texture assigned." % i)

	_compute_lane_centers_and_line()
	_build_receptors()
	_build_hud()

	# Build pending notes from chart
	for entry in CHART_BEATS:
		var n: NoteInfo = NoteInfo.new()
		n.beat = float(entry[0])
		n.lane = int(entry[1])
		n.node = null
		notes_pending.append(n)

	# Schedule gameplay start (countdown)
	game_start_time = _now_sec() + float(countdown_seconds)
	started = false
	ended = false

func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		_recompute_layout()

# ---------- Layout / Resize ----------
func _compute_lane_centers_and_line() -> void:
	var vp: Vector2 = get_viewport_rect().size
	timing_line_y = vp.y * timing_line_y_factor

	var total_width: float = lane_spacing * 3.0          # 4 lanes => 3 gaps
	var start_x: float = (vp.x - total_width) * 0.5      # left edge of the centered block

	lane_x.resize(4)
	for i in range(4):
		lane_x[i] = start_x + i * lane_spacing           # lane center X

func _build_receptors() -> void:
	# clear old
	for r in receptors:
		if is_instance_valid(r):
			r.queue_free()
	receptors.clear()

	# create dim receptors at timing line
	for lane in range(4):
		var r: TextureRect = TextureRect.new()
		r.texture = _lane_tex[lane]
		r.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
		r.scale = Vector2.ONE * note_scale

		var tex_sz: Vector2 = _tex_size(_lane_tex[lane]) * note_scale
		r.custom_minimum_size = tex_sz
		r.size = tex_sz
		r.position = Vector2(lane_x[lane] - tex_sz.x * 0.5, timing_line_y - tex_sz.y * 0.5)
		r.modulate.a = receptor_alpha
		add_child(r)
		receptors.append(r)

func _build_hud() -> void:
	hud = CanvasLayer.new()
	hud.layer = 100
	add_child(hud)

	score_label = Label.new()
	score_label.text = "Score: 0"
	score_label.position = Vector2(20, 20)
	score_label.add_theme_color_override("font_color", Color(1, 1, 0))
	hud.add_child(score_label)

	combo_label = Label.new()
	combo_label.text = ""
	combo_label.position = Vector2(20, 60)
	combo_label.visible = false
	combo_label.add_theme_color_override("font_color", Color(0.7, 1.0, 1.0))
	hud.add_child(combo_label)

	result_label = Label.new()
	result_label.text = ""
	result_label.visible = false
	result_label.add_theme_color_override("font_color", Color(1, 1, 1))
	result_label.add_theme_font_size_override("font_size", 32)
	result_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	result_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	hud.add_child(result_label)

	countdown_label = Label.new()
	countdown_label.text = ""
	countdown_label.visible = true
	countdown_label.add_theme_color_override("font_color", Color(1, 1, 1))
	countdown_label.add_theme_font_size_override("font_size", 48)
	countdown_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	countdown_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	hud.add_child(countdown_label)

	_recenter_hud()

func _recenter_hud() -> void:
	var vp: Vector2 = get_viewport_rect().size
	# center result (slightly above middle)
	result_label.position = Vector2(vp.x * 0.5 - 140.0, vp.y * 0.4)
	# center countdown (a bit higher)
	countdown_label.position = Vector2(vp.x * 0.5 - 24.0, vp.y * 0.3)

func _recompute_layout() -> void:
	_compute_lane_centers_and_line()

	# Reposition receptors
	for lane in range(min(4, receptors.size())):
		var r: TextureRect = receptors[lane]
		if is_instance_valid(r):
			var tex_sz: Vector2 = r.size
			r.position = Vector2(lane_x[lane] - tex_sz.x * 0.5, timing_line_y - tex_sz.y * 0.5)

	# Re-center live notes to lane centers (keep Y)
	for info in notes_live:
		if info.node and is_instance_valid(info.node):
			var tex_sz2: Vector2 = info.node.size
			info.node.position.x = lane_x[info.lane] - tex_sz2.x * 0.5

	_recenter_hud()

# ---------- Countdown ----------
func _time_until_start() -> float:
	return game_start_time - _now_sec()

func _update_countdown() -> void:
	var remaining: float = _time_until_start()
	if remaining > 0.0:
		var whole: int = int(ceil(remaining))
		countdown_label.visible = true
		countdown_label.modulate.a = 1.0  # ensure fully visible while counting
		countdown_label.text = str(whole)
	elif not started:
		_start_game()

func _start_game() -> void:
	started = true
	countdown_label.text = "GO!"
	countdown_label.visible = true

	# Start the song exactly at GO (if present)
	if song:
		song.play()

	# Fade out "GO!"
	var tween := create_tween()
	tween.tween_property(countdown_label, "modulate:a", 0.0, 0.6)
	tween.finished.connect(func ():
		if is_instance_valid(countdown_label):
			countdown_label.visible = false
			countdown_label.modulate.a = 1.0)

# ---------- Score / Combo ----------
func _award_hit() -> void:
	score += 100
	if score_label:
		score_label.text = "Score: %d" % score

	combo += 1
	if combo >= 3:
		combo_label.visible = true
		combo_label.text = "Combo: %d" % combo

func _register_miss() -> void:
	if combo > 0:
		combo = 0
		combo_label.visible = false

# ---------- Finish logic ----------
func _maybe_finish_chart() -> void:
	if ended:
		return
	if notes_pending.is_empty() and notes_live.is_empty() and started:
		_finish_chart()

func _finish_chart() -> void:
	ended = true
	if song:
		song.stop()
	var msg: String = ("You Win!" if score >= target_score else "You Lose!")
	result_label.text = "%s\nScore: %d / %d" % [msg, score, target_score]
	result_label.visible = true

# ---------- Main loop ----------
func _process(dt: float) -> void:
	# Handle pre-start countdown and block gameplay until started
	_update_countdown()
	if not started:
		return

	var t_now: float = _song_time_seconds()

	# Spawn with lookahead
	for i in range(notes_pending.size() - 1, -1, -1):
		var info: NoteInfo = notes_pending[i]
		var t_hit: float = beat_to_seconds(info.beat)
		var time_until_hit: float = t_hit - t_now
		if time_until_hit <= spawn_lookahead_sec:
			_spawn_note(info, max(0.0, time_until_hit))
			notes_pending.remove_at(i)

	# Move & cull late misses
	for i in range(notes_live.size() - 1, -1, -1):
		var info2: NoteInfo = notes_live[i]
		info2.node.position.y += note_speed_px_s * dt

		if _note_center_y(info2.node) > timing_line_y + (timing_window_px + 60.0):
			print("Miss (late): lane ", info2.lane, " beat ", info2.beat)
			_register_miss()
			info2.node.queue_free()
			notes_live.remove_at(i)

	# Inputs
	if Input.is_action_just_pressed("hit_left"):  _try_hit(0)
	if Input.is_action_just_pressed("hit_down"):  _try_hit(1)
	if Input.is_action_just_pressed("hit_up"):    _try_hit(2)
	if Input.is_action_just_pressed("hit_right"): _try_hit(3)

	_maybe_finish_chart()

# ---------- Spawning / Hitting ----------
func _spawn_note(info: NoteInfo, time_until_hit: float) -> void:
	var tex: Texture2D = _lane_tex[info.lane]
	if tex == null:
		return

	var note: TextureRect = TextureRect.new()
	note.texture = tex
	note.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
	note.scale = Vector2.ONE * note_scale

	var tex_sz: Vector2 = _tex_size(tex) * note_scale
	note.custom_minimum_size = tex_sz
	note.size = tex_sz

	note.position = Vector2(
		lane_x[info.lane] - tex_sz.x * 0.5,
		_spawn_y_for_time_to_line(time_until_hit, tex_sz.y)
	)

	add_child(note)
	info.node = note
	notes_live.append(info)

func _try_hit(lane: int) -> void:
	var best_idx: int = -1
	var best_dist: float = INF

	for i in range(notes_live.size()):
		var info: NoteInfo = notes_live[i]
		if info.lane != lane:
			continue
		var d: float = abs(_note_center_y(info.node) - timing_line_y)
		if d < best_dist:
			best_dist = d
			best_idx = i

	if best_idx == -1:
		print("Miss (no note) on lane ", lane)
		_register_miss()
		return

	if best_dist <= timing_window_px:
		var q: String = (
			"Perfect" if best_dist < timing_window_px * 0.35
			else ("Good" if best_dist < timing_window_px * 0.7 else "Okay")
		)
		print("%s hit lane %d (Δ=%.1f px)" % [q, lane, best_dist])

		_award_hit()

		var hit: NoteInfo = notes_live[best_idx]
		hit.node.queue_free()
		notes_live.remove_at(best_idx)
	else:
		print("Miss (off timing) lane %d (Δ=%.1f px)" % [lane, best_dist])
		_register_miss()
