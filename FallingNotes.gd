extends Control

# --- Helper type to store each note cleanly ---
class NoteInfo:
	var node: TextureRect
	var lane: int

# --- Assign your arrow textures in the Inspector ---
@export var left_tex:  Texture2D
@export var down_tex:  Texture2D
@export var up_tex:    Texture2D
@export var right_tex: Texture2D

# Optional: scale notes/receptors if your textures are large/small
@export var note_scale: float = 1.0
@export var receptor_alpha: float = 0.45

# --- Tuning ---
const NOTE_SPEED: float = 420.0                 # px/sec downward
const TIMING_LINE_Y_FACTOR: float = 0.80        # 0..1 of screen height
const TIMING_WINDOW_PIXELS: float = 40.0        # hit window (pixels)
const SPAWN_INTERVAL: float = 0.6               # seconds between spawns

# lanes: 0=left, 1=down, 2=up, 3=right
var lane_x: Array[float] = []
var timing_line_y: float = 0.0
var notes: Array[NoteInfo] = []

var _spawn_timer: float = 0.0
var _lane_tex: Array[Texture2D] = []

func _ready() -> void:
	# Build lane->texture table (order must match input lanes)
	_lane_tex = [left_tex, down_tex, up_tex, right_tex]
	for i in range(_lane_tex.size()):
		if _lane_tex[i] == null:
			push_warning("Lane %d has no texture assigned in the Inspector." % i)

	var size: Vector2 = get_viewport_rect().size
	timing_line_y = size.y * TIMING_LINE_Y_FACTOR

	var center: float = size.x * 0.5
	var spacing: float = 100.0
	lane_x = [center - 1.5 * spacing, center - 0.5 * spacing, center + 0.5 * spacing, center + 1.5 * spacing]

	# Receptors at timing line (dimmed)
	for lane in range(4):
		var r := TextureRect.new()
		r.texture = _lane_tex[lane]
		r.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
		r.pivot_offset = Vector2.ZERO
		r.scale = Vector2.ONE * note_scale
		add_child(r)

		# Size/position from texture
		var tex_size: Vector2 = _get_tex_size(_lane_tex[lane]) * note_scale
		r.custom_minimum_size = tex_size
		r.size = tex_size
		r.position = Vector2(lane_x[lane] - tex_size.x * 0.5, timing_line_y - tex_size.y * 0.5)
		r.modulate.a = receptor_alpha  # dim

func _process(dt: float) -> void:
	# demo spawner
	_spawn_timer -= dt
	if _spawn_timer <= 0.0:
		_spawn_timer = SPAWN_INTERVAL
		_spawn_note(randi() % 4)

	# move notes & cull late misses
	for i in range(notes.size() - 1, -1, -1):
		var info: NoteInfo = notes[i]
		info.node.position.y += NOTE_SPEED * dt

		if info.node.position.y > timing_line_y + TIMING_WINDOW_PIXELS + 80.0:
			print("Miss (late): lane ", info.lane)
			info.node.queue_free()
			notes.remove_at(i)

	# input
	if Input.is_action_just_pressed("hit_left"):
		_try_hit(0)
	if Input.is_action_just_pressed("hit_down"):
		_try_hit(1)
	if Input.is_action_just_pressed("hit_up"):
		_try_hit(2)
	if Input.is_action_just_pressed("hit_right"):
		_try_hit(3)

func _spawn_note(lane: int) -> void:
	var tex := _lane_tex[lane]
	if tex == null:
		return

	var note := TextureRect.new()
	note.texture = tex
	note.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
	note.scale = Vector2.ONE * note_scale
	add_child(note)

	var tex_size: Vector2 = _get_tex_size(tex) * note_scale
	note.custom_minimum_size = tex_size
	note.size = tex_size

	# Start above the screen, centered on lane
	note.position = Vector2(lane_x[lane] - tex_size.x * 0.5, -tex_size.y)

	var info := NoteInfo.new()
	info.node = note
	info.lane = lane
	notes.append(info)

func _try_hit(lane: int) -> void:
	var best_idx: int = -1
	var best_dist: float = INF

	for i in range(notes.size()):
		var info: NoteInfo = notes[i]
		if info.lane != lane:
			continue
		# compare note center to timing line
		var note_center_y: float = info.node.position.y + info.node.size.y * 0.5
		var d: float = abs(note_center_y - timing_line_y)
		if d < best_dist:
			best_dist = d
			best_idx = i

	if best_idx == -1:
		print("Miss (no note) on lane ", lane)
		return

	if best_dist <= TIMING_WINDOW_PIXELS:
		var quality := (
			"Perfect" if best_dist < TIMING_WINDOW_PIXELS * 0.35
			else ("Good" if best_dist < TIMING_WINDOW_PIXELS * 0.7 else "Okay")
		)
		print("%s hit on lane %d (Δ=%.1f px)" % [quality, lane, best_dist])
		var hit: NoteInfo = notes[best_idx]
		hit.node.queue_free()
		notes.remove_at(best_idx)
	else:
		print("Miss (off timing) on lane %d (Δ=%.1f px)" % [lane, best_dist])

func _get_tex_size(tex: Texture2D) -> Vector2:
	return tex.get_size() if tex != null else Vector2(48, 48)
