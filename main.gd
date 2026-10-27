extends Node2D
## BOUND (craftM, 2000) remake.
## Game logic runs at 20 ticks/s like the original and the ball is drawn as a line
## from its previous position to its current one (the original's afterimage).
## Physics constants were measured from the reference video (game px per tick),
## then slowed by TIME_SCALE: speeds scale by it and accelerations by its square,
## so heights and distances stay the same while everything plays slower.

const TILE := 32
const COLS := 20
const ROWS := 15
const SCREEN := Vector2(640, 480)
const TICK := 0.05

const TIME_SCALE := 0.65    # the original plays at ~0.5-0.8x the measured speed
const GRAVITY := 3.75 * TIME_SCALE * TIME_SCALE
const BOUNCE_V := 13.15     # ~1.5 tiles high
const JUMP_V := 34.6 * TIME_SCALE         # ~4.5 tiles high
const MAX_FALL := 21.0 * TIME_SCALE
const ACCEL := 1.0 * TIME_SCALE * TIME_SCALE
const MAX_VX := 9.0 * TIME_SCALE
const KICK_ANGLE := deg_to_rad(35.0)      # wall climb flies straight up-and-away at this angle
const KICK_DIST := 64.0                   # ...for this far (3 kicks climb stage 5's start shaft)
const KICK_SPEED := 9.0
const DASH_V := 24.0 * TIME_SCALE         # dash block speed
const BALL_R := 4.0

const START_LIVES := 3
const INTERMISSION_TIME := 2.0
const DEATH_TIME := 1.2

const SOLID := ["#", "G", "J", "X"]

enum State { INTERMISSION, PLAY, DYING, ALL_CLEAR }

var state := State.INTERMISSION
var stage := 0
var lives := START_LIVES
var timer := 0.0
var tick_acc := 0.0

var map := []               # Array of Array of single-char Strings
var pos := Vector2.ZERO
var prev_pos := Vector2.ZERO
var vel := Vector2.ZERO
var dashing := 0            # -1/1 while flying from a dash block
var dash_tile := Vector2i(-1, -1)
var wall_side := 0          # -1/1 while resting against a wall the ball ran into
var kick_dir := 0           # -1/1 while flying off a wall kick
var kick_left := 0.0        # distance left in the current wall kick flight
var prev_pos2 := Vector2.ZERO   # position two ticks ago, for the afterimage tail

var left_held := false
var right_held := false
var first_dir := 1          # direction of the key pressed first while both are held

var flash_pos := Vector2.ZERO
var flash_ticks := 0
var particles := []         # [pos, vel] pairs for the explosion

var font: Font


func _ready() -> void:
	font = ThemeDB.fallback_font
	start_intermission()


func start_intermission() -> void:
	state = State.INTERMISSION
	timer = INTERMISSION_TIME
	queue_redraw()


func load_stage() -> void:
	map.clear()
	var rows: Array = Levels.STAGES[stage]
	for y in ROWS:
		var row := []
		for x in COLS:
			var c: String = rows[y][x]
			if c == "S":
				pos = Vector2(x * TILE + TILE / 2.0, y * TILE + TILE / 2.0)
				c = "."
			row.append(c)
		map.append(row)
	prev_pos = pos
	prev_pos2 = pos
	vel = Vector2.ZERO
	dashing = 0
	dash_tile = Vector2i(-1, -1)
	wall_side = 0
	kick_dir = 0
	kick_left = 0.0
	flash_ticks = 0
	particles.clear()
	tick_acc = 0.0
	state = State.PLAY


func _process(delta: float) -> void:
	read_input()
	match state:
		State.INTERMISSION:
			timer -= delta
			if timer <= 0.0:
				load_stage()
		State.PLAY, State.DYING:
			tick_acc += delta
			while tick_acc >= TICK:
				tick_acc -= TICK
				if state == State.PLAY:
					tick()
				else:
					tick_death()
				if state != State.PLAY and state != State.DYING:
					break
		State.ALL_CLEAR:
			pass
	queue_redraw()


func _unhandled_input(event: InputEvent) -> void:
	if state == State.ALL_CLEAR and event is InputEventKey and event.pressed and not event.echo:
		stage = 0
		lives = START_LIVES
		start_intermission()


func read_input() -> void:
	var l := Input.is_key_pressed(KEY_LEFT)
	var r := Input.is_key_pressed(KEY_RIGHT)
	if l and r:
		if l and not left_held and right_held:
			first_dir = 1
		elif r and not right_held and left_held:
			first_dir = -1
	left_held = l
	right_held = r


func input_dir() -> int:
	if left_held and right_held:
		return first_dir
	if left_held:
		return -1
	if right_held:
		return 1
	return 0


# --- simulation -------------------------------------------------------------

func tick() -> void:
	prev_pos2 = prev_pos
	prev_pos = pos
	if flash_ticks > 0:
		flash_ticks -= 1

	if dashing != 0:
		tick_dash()
	elif kick_left > 0.0:
		tick_kick()
	else:
		tick_normal()
	if state != State.PLAY:
		return
	if pos.x - BALL_R > SCREEN.x:
		stage_clear()
	elif pos.y - BALL_R > SCREEN.y:
		die(false)


func tick_normal() -> void:
	# Wall climb: pressing away from a wall the ball is touching kicks it off.
	if wall_side != 0:
		if not touching(wall_side):
			wall_side = 0
		elif right_held if wall_side < 0 else left_held:
			wall_kick(wall_side)
			tick_kick()
			return
	var dir := input_dir()
	if dir != 0:
		vel.x = clampf(vel.x + dir * ACCEL, -MAX_VX, MAX_VX)
	else:
		vel.x = move_toward(vel.x, 0.0, ACCEL)
	vel.y = minf(vel.y + GRAVITY, MAX_FALL)

	var steps := maxi(int(ceil(maxf(absf(vel.x), absf(vel.y)) / 4.0)), 1)
	var dx := vel.x / steps
	var dy := vel.y / steps
	var x_blocked := false
	var y_blocked := false
	for i in steps:
		if not x_blocked and dx != 0.0:
			x_blocked = move_x(dx)
			if state != State.PLAY or kick_left > 0.0:
				return
		if not y_blocked and dy != 0.0:
			y_blocked = move_y(dy)
			if state != State.PLAY:
				return
		if try_dash():
			return


## Flies flat along the dash block's row until a wall, or the opposite key stops it.
func tick_dash() -> void:
	if (dashing > 0 and left_held) or (dashing < 0 and right_held):
		dashing = 0
		vel = Vector2.ZERO
		return
	var steps := int(ceil(DASH_V / 4.0))
	for i in steps:
		pos.x += dashing * DASH_V / steps
		var hits := overlapping_tiles()
		if hits.is_empty():
			continue
		if has_type(hits, "X"):
			die(true)
			return
		if dashing > 0:
			pos.x = min_tile_edge(hits, true) - BALL_R - 0.01
		else:
			pos.x = max_tile_edge(hits, true) + BALL_R + 0.01
		wall_side = dashing
		dashing = 0
		vel = Vector2.ZERO
		return


## Starts a dash when the ball's center enters a dash block.
func try_dash() -> bool:
	var tx := int(floor(pos.x / TILE))
	var ty := int(floor(pos.y / TILE))
	if tile_at(tx, ty) != "A":
		dash_tile = Vector2i(-1, -1)
		return false
	if dash_tile == Vector2i(tx, ty):
		return false        # still inside the block that just fired us
	dash_tile = Vector2i(tx, ty)
	dashing = int(signf(vel.x))
	if dashing == 0:
		dashing = input_dir() if input_dir() != 0 else 1
	pos.y = ty * TILE + TILE / 2.0
	vel = Vector2.ZERO
	return true


## Moves horizontally; returns true when a wall stopped the ball.
func move_x(dx: float) -> bool:
	pos.x += dx
	var hits := overlapping_tiles()
	if hits.is_empty():
		return false
	if has_type(hits, "X"):
		die(true)
		return true
	var wall_dir := signi(int(signf(dx)))
	if dx > 0.0:
		pos.x = min_tile_edge(hits, true) - BALL_R - 0.01
	else:
		pos.x = max_tile_edge(hits, true) + BALL_R + 0.01
	vel.x = 0.0
	wall_side = wall_dir
	# Already holding the key away from the wall at contact: kick off right away.
	if right_held if wall_dir < 0 else left_held:
		wall_kick(wall_dir)
	return true


func wall_kick(side: int) -> void:
	kick_dir = -side
	kick_left = KICK_DIST
	wall_side = 0
	flash_pos = pos + Vector2(side * BALL_R, 0)
	flash_ticks = 3


## Flies in a straight line, ignoring gravity and the keys, until the kick
## distance runs out or something is hit; then normal physics take over with
## the flight's velocity.
func tick_kick() -> void:
	var d := minf(KICK_SPEED, kick_left)
	kick_left -= d
	var steps := int(ceil(d / 4.0))
	var step := Vector2(kick_dir * cos(KICK_ANGLE), -sin(KICK_ANGLE)) * d / steps
	vel = Vector2(kick_dir * minf(KICK_SPEED * cos(KICK_ANGLE), MAX_VX), -KICK_SPEED * sin(KICK_ANGLE))
	for i in steps:
		var dir := kick_dir
		if move_x(step.x):
			if kick_dir == dir:
				kick_left = 0.0     # stopped by the wall; a new kick sets kick_dir anew
			return
		if state != State.PLAY:
			return
		if move_y(step.y):
			kick_left = 0.0
			return
		if state != State.PLAY:
			return
		if try_dash():
			kick_left = 0.0
			return


## True when a solid tile sits right next to the ball on the given side.
func touching(side: int) -> bool:
	pos.x += side
	var hit := not overlapping_tiles().is_empty()
	pos.x -= side
	return hit


## Moves vertically; returns true when a floor or ceiling stopped the ball.
func move_y(dy: float) -> bool:
	pos.y += dy
	var hits := overlapping_tiles()
	if hits.is_empty():
		return false
	if has_type(hits, "X"):
		die(true)
		return true
	if dy > 0.0:
		pos.y = min_tile_edge(hits, false) - BALL_R - 0.01
		vel.y = -JUMP_V if has_type(hits, "J") else -BOUNCE_V
		for h in hits:
			if h.z == 1:  # breakable: disappears once stepped on
				map[h.y][h.x] = "."
	else:
		pos.y = max_tile_edge(hits, false) + BALL_R + 0.01
		vel.y = 0.0
	return true


## Solid tiles touched by the ball box. Each entry is Vector3i(x, y, is_breakable).
func overlapping_tiles() -> Array:
	var out := []
	var x0 := int(floor((pos.x - BALL_R) / TILE))
	var x1 := int(floor((pos.x + BALL_R) / TILE))
	var y0 := int(floor((pos.y - BALL_R) / TILE))
	var y1 := int(floor((pos.y + BALL_R) / TILE))
	for ty in range(y0, y1 + 1):
		for tx in range(x0, x1 + 1):
			var c := tile_at(tx, ty)
			if c in SOLID:
				out.append(Vector3i(tx, ty, 1 if c == "G" else 0))
	return out


func tile_at(tx: int, ty: int) -> String:
	if tx >= COLS or ty >= ROWS:
		return "."          # open to the right (exit) and bottom (pit)
	if tx < 0 or ty < 0:
		return "#"
	return map[ty][tx]


func has_type(hits: Array, c: String) -> bool:
	for h in hits:
		if tile_at(h.x, h.y) == c:
			return true
	return false


func min_tile_edge(hits: Array, horizontal: bool) -> float:
	var v := INF
	for h in hits:
		v = minf(v, (h.x if horizontal else h.y) * TILE)
	return v


func max_tile_edge(hits: Array, horizontal: bool) -> float:
	var v := -INF
	for h in hits:
		v = maxf(v, ((h.x if horizontal else h.y) + 1) * TILE)
	return v


func die(exploded: bool) -> void:
	state = State.DYING
	timer = DEATH_TIME
	particles.clear()
	if exploded:
		for i in 24:
			var a := TAU * i / 24.0
			var s := randf_range(3.0, 9.0)
			particles.append([pos, Vector2(cos(a), sin(a)) * s])


func tick_death() -> void:
	prev_pos = pos
	for p in particles:
		p[0] += p[1]
		p[1].y += 0.6
	timer -= TICK
	if timer <= 0.0:
		lives -= 1
		if lives <= 0:
			lives = START_LIVES
			stage = 0
		start_intermission()


func stage_clear() -> void:
	stage += 1
	if stage >= Levels.STAGES.size():
		state = State.ALL_CLEAR
	else:
		start_intermission()


# --- rendering --------------------------------------------------------------

func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, SCREEN), Color.BLACK)
	match state:
		State.INTERMISSION:
			var x := 243.0
			draw_string(font, Vector2(x, 165), "Stage  %d" % stage, HORIZONTAL_ALIGNMENT_LEFT, -1, 13)
			draw_string(font, Vector2(x, 187), "%d Bound" % lives, HORIZONTAL_ALIGNMENT_LEFT, -1, 13)
		State.ALL_CLEAR:
			draw_string(font, Vector2(0, 230), "ALL CLEAR", HORIZONTAL_ALIGNMENT_CENTER, SCREEN.x, 24)
			draw_string(font, Vector2(0, 260), "press any key", HORIZONTAL_ALIGNMENT_CENTER, SCREEN.x, 13)
		_:
			draw_exit_glow()
			draw_map()
			draw_ball()


## Faint pulsing light on the open cells of the right edge, where the exit is.
func draw_exit_glow() -> void:
	const STRIPS := 12
	const STRIP_W := 6.0
	for y in ROWS:
		if map[y][COLS - 1] != ".":
			continue
		for i in STRIPS:
			var a := 0.14 * pow(float(i + 1) / STRIPS, 2.0)
			var x := SCREEN.x - (STRIPS - i) * STRIP_W
			draw_rect(Rect2(x, y * TILE, STRIP_W, TILE), Color(1.0, 0.95, 0.7, a))


func draw_map() -> void:
	for y in ROWS:
		for x in COLS:
			var c: String = map[y][x]
			if c == ".":
				continue
			var r := Rect2(x * TILE, y * TILE, TILE, TILE)
			match c:
				"#": draw_brick(r)
				"G": draw_breakable(r)
				"J": draw_jump(r)
				"A": draw_dash(r)
				"X": draw_bomb(r)


func draw_brick(r: Rect2) -> void:
	draw_rect(r, Color8(144, 72, 64))
	draw_rect(r.grow(-1), Color8(224, 112, 96))
	draw_rect(r.grow(-2), Color8(208, 112, 80))
	draw_rect(r.grow(-3), Color8(232, 136, 88))


func draw_breakable(r: Rect2) -> void:
	draw_rect(r, Color8(64, 48, 48))
	draw_rect(r.grow(-1), Color8(112, 96, 96))
	draw_rect(r.grow(-3), Color8(136, 128, 120))
	draw_rect(r.grow(-5), Color8(152, 136, 120))
	for o in [Vector2(4, 4), Vector2(26, 4), Vector2(4, 26), Vector2(26, 26)]:
		draw_rect(Rect2(r.position + o, Vector2(2, 2)), Color8(187, 187, 187))


func draw_jump(r: Rect2) -> void:
	draw_rect(r, Color8(32, 48, 64))
	draw_rect(r.grow(-1), Color8(96, 144, 168))
	draw_rect(r.grow(-2), Color8(80, 136, 160))
	draw_rect(r.grow(-3), Color8(68, 136, 153))
	draw_rect(Rect2(r.position.x + 2, r.end.y - 2, TILE - 4, 1), Color8(144, 192, 208))


func draw_dash(r: Rect2) -> void:
	var b := r.grow(-1)
	draw_rect(b, Color8(32, 16, 16))
	draw_rect(b.grow(-1), Color8(240, 192, 128))
	draw_rect(b.grow(-2), Color8(250, 170, 100))
	for o in [Vector2(5, 5), Vector2(25, 5), Vector2(5, 25), Vector2(25, 25)]:
		draw_rect(Rect2(r.position + o, Vector2(3, 2)), Color8(150, 112, 80))


func draw_bomb(r: Rect2) -> void:
	draw_rect(r.grow(-1), Color8(48, 48, 48))
	# The original pulses the bomb picture.
	var rad := 9.0 + 1.5 * sin(Time.get_ticks_msec() / 150.0)
	draw_circle(r.get_center(), rad, Color8(16, 16, 16))
	draw_rect(Rect2(r.get_center() + Vector2(2, -rad - 3), Vector2(2, 4)), Color8(240, 120, 40))


func draw_ball() -> void:
	if state == State.DYING:
		for p in particles:
			draw_rect(Rect2(p[0] - Vector2(1, 1), Vector2(2, 2)), Color.WHITE)
		return
	if prev_pos2.distance_to(pos) < 1.0:
		draw_rect(Rect2(pos - Vector2(1, 4), Vector2(2, 8)), Color.WHITE)
	else:
		# Afterimage: the path over the last two ticks.
		draw_polyline(PackedVector2Array([prev_pos2, prev_pos, pos]), Color.WHITE, 2.0)
	if flash_ticks > 0:
		var rad := 4.0 + (3 - flash_ticks) * 4.0
		draw_arc(flash_pos, rad, 0, TAU, 16, Color.WHITE, 1.0)
