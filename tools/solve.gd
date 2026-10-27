extends SceneTree
## Dev check: BFS over per-tick inputs to confirm every stage can be cleared
## with the current physics.
## Run: godot --headless --script res://tools/solve.gd [-- <stage> ...]

const MainScript := preload("res://main.gd")
# [left_held, right_held, first_dir]
const ACTIONS := [[false, false, 1], [true, false, 1], [false, true, 1], [true, true, 1], [true, true, -1]]
const MAX_NODES := 9000000


func _init() -> void:
	var g = MainScript.new()
	var stages := []
	for a in OS.get_cmdline_user_args():
		stages.append(int(a))
	if stages.is_empty():
		stages = range(Levels.STAGES.size())
	for s in stages:
		var t0 := Time.get_ticks_msec()
		var res := solve(g, s)
		print("stage %d: %s (%d ms)" % [s, res, Time.get_ticks_msec() - t0])
	g.free()
	quit()


func solve(g, s: int) -> String:
	g.stage = s
	g.load_stage()
	var gtiles := []
	for y in g.ROWS:
		for x in g.COLS:
			if g.map[y][x] == "G":
				gtiles.append(Vector2i(x, y))
	# pos, vel, broken mask, depth, dashing, dash_tile, wall_side, kick_dir, kick_left
	var queue := [[g.pos, g.vel, 0, 0, 0, Vector2i(-1, -1), 0, 0, 0.0]]
	var seen := {}
	var head := 0
	while head < queue.size():
		if queue.size() > MAX_NODES:
			return "UNKNOWN (search limit, %d nodes)" % queue.size()
		var n: Array = queue[head]
		head += 1
		for a in ACTIONS:
			g.stage = s
			g.state = g.State.PLAY
			g.pos = n[0]
			g.vel = n[1]
			g.dashing = n[4]
			g.dash_tile = n[5]
			g.wall_side = n[6]
			g.kick_dir = n[7]
			g.kick_left = n[8]
			for i in gtiles.size():
				var t: Vector2i = gtiles[i]
				g.map[t.y][t.x] = "." if (n[2] >> i) & 1 else "G"
			g.left_held = a[0]
			g.right_held = a[1]
			g.first_dir = a[2]
			g.tick()
			if g.state == g.State.DYING:
				continue
			if g.state != g.State.PLAY:
				return "CLEARABLE in %d ticks (%.1fs)" % [n[3] + 1, (n[3] + 1) * g.TICK]
			var mask := 0
			for i in gtiles.size():
				var t: Vector2i = gtiles[i]
				if g.map[t.y][t.x] == ".":
					mask |= 1 << i
			var key := [roundi(g.pos.x / 4.0), roundi(g.pos.y / 4.0), roundi(g.vel.x / g.ACCEL), roundi(g.vel.y / g.GRAVITY), mask, g.dashing, g.wall_side, g.kick_dir, roundi(g.kick_left)]
			if seen.has(key):
				continue
			seen[key] = true
			queue.append([g.pos, g.vel, mask, n[3] + 1, g.dashing, g.dash_tile, g.wall_side, g.kick_dir, g.kick_left])
	return "NOT CLEARABLE (%d nodes)" % queue.size()
