// Zigsteroids 2 — Asteroids rebuilt on the vgame platform
//
// A Zig implementation of the classic 1979 Atari arcade game Asteroids,
// rewritten to use the zigvectorgames (vgame) library for window management,
// screen scaling, rendering, input, audio, particles, and overlays.
//
// Controls:
//   LEFT/RIGHT  Rotate ship
//   UP / W      Thrust
//   DOWN        Shields
//   SPACE/CLICK Shoot
//   H / P       Pause / Help
//   1           New Game
//   F           Toggle fullscreen (handled by vgame platform)
//
// Gamepad:
//   LS / D-PAD  Rotate
//   RT / X      Thrust
//   B / LT      Shields
//   A           Shoot
//   Start       Pause / New Game

const std = @import("std");
const math = std.math;
const Random = std.Random;

const vgame = @import("vgame");
const rl = vgame.rl;
const rlm = rl.math;
const Vector2 = vgame.Vector2;

// ── Game actions ──────────────────────────────────────────────────
const Action = enum {
    rotate_left,
    rotate_right,
    thrust,
    shield,
    shoot,
    pause,
    new_game,
};

const action_count = @typeInfo(Action).@"enum".fields.len;

// ── Input bindings ────────────────────────────────────────────────
const keyboard_bindings = [_]?vgame.KeyBinding{
    .{ .key = .left, .edge = false }, // rotate_left
    .{ .key = .right, .edge = false }, // rotate_right
    .{ .key = .up, .edge = false }, // thrust (also 'w' handled below)
    .{ .key = .down, .edge = true }, // shield
    .{ .key = .space, .edge = true }, // shoot
    .{ .key = .h, .edge = true }, // pause
    .{ .key = .one, .edge = true }, // new_game
};

const gamepad_bindings = [_]?vgame.GamepadBinding{
    .{ .button = .left_face_left }, // rotate_left
    .{ .button = .left_face_right }, // rotate_right
    .{ .trigger = .right_trigger, .threshold = 0.1 }, // thrust
    .{ .button = .right_face_right }, // shield (B)
    .{ .button = .right_face_down }, // shoot (A)
    .{ .button = .middle_right }, // pause (Start)
    .{ .button = .middle_right }, // new_game (Start)
};

const bindings = vgame.InputBindings{
    .keyboard = &keyboard_bindings,
    .gamepad = &gamepad_bindings,
};

// ── Sound effect indices ──────────────────────────────────────────
const SFX = enum(usize) {
    bloop_lo,
    bloop_hi,
    shoot,
    thrust,
    asteroid,
    explode,
    berzerk_coin,
};

const sound_clips = [_][]const u8{
    "bloop_lo.wav",
    "bloop_hi.wav",
    "shoot.wav",
    "thrust.wav",
    "asteroid.wav",
    "explode.wav",
    "berzerk_coin_detected.wav",
};

// ── Constants ─────────────────────────────────────────────────────
const QUANTUM_REMATERIZATION_LIMIT: u32 = 1200;
const SHIELD_DURATION: f32 = 2.0;
const SHIELD_RECHARGE: f32 = 25.0;
const FIELD_GRID_DIV: i32 = 3;
const BERZERK_COIN_INTERVAL: f32 = 30.0;

// ── Game structs ──────────────────────────────────────────────────

const Ship = struct {
    pos: Vector2,
    vel: Vector2,
    rot: f32,
    death_time: f32 = 0.0,

    fn isDead(self: @This()) bool {
        return self.death_time != 0.0;
    }
};

const AsteroidSize = enum {
    BIG,
    MEDIUM,
    SMALL,

    fn score(self: @This()) usize {
        return switch (self) {
            .BIG => 20,
            .MEDIUM => 50,
            .SMALL => 100,
        };
    }

    fn drawSize(self: @This(), scale: f32) f32 {
        return switch (self) {
            .BIG => scale * 3.0,
            .MEDIUM => scale * 1.4,
            .SMALL => scale * 0.8,
        };
    }

    fn collisionScale(self: @This()) f32 {
        return switch (self) {
            .BIG => 0.4,
            .MEDIUM => 0.65,
            .SMALL => 1.0,
        };
    }

    fn velocityScale(self: @This()) f32 {
        return switch (self) {
            .BIG => 0.75,
            .MEDIUM => 1.8,
            .SMALL => 3.0,
        };
    }
};

const Asteroid = struct {
    pos: Vector2,
    vel: Vector2,
    size: AsteroidSize,
    seed: u64,
    remove: bool = false,
};

const AlienSize = enum {
    BIG,
    SMALL,

    fn collisionSize(self: @This(), scale: f32) f32 {
        return switch (self) {
            .BIG => scale * 0.7,
            .SMALL => scale * 0.6,
        };
    }

    fn dirChangeTime(self: @This()) f32 {
        return switch (self) {
            .BIG => 0.85,
            .SMALL => 0.55,
        };
    }

    fn shotTime(self: @This()) f32 {
        return switch (self) {
            .BIG => 2.55,
            .SMALL => 2.05,
        };
    }

    fn speed(self: @This()) f32 {
        return switch (self) {
            .BIG => 2,
            .SMALL => 4,
        };
    }
};

const Alien = struct {
    pos: Vector2,
    dir: Vector2,
    size: AlienSize,
    remove: bool = false,
    last_shot: f32 = 0,
    last_dir: f32 = 0,
};

const Projectile = struct {
    pos: Vector2,
    vel: Vector2,
    ttl: f32,
    spawn: f32,
    player: bool = false,
    remove: bool = false,
};

// ── Vector shapes ─────────────────────────────────────────────────

const SHIP_LINES = [_]Vector2{
    .{ .x = -0.4, .y = -0.5 },
    .{ .x = 0.0, .y = 0.5 },
    .{ .x = 0.4, .y = -0.5 },
    .{ .x = 0.3, .y = -0.4 },
    .{ .x = -0.3, .y = -0.4 },
};

const THRUST_LINES = [_]Vector2{
    .{ .x = -0.3, .y = -0.4 },
    .{ .x = 0.0, .y = -1.0 },
    .{ .x = 0.3, .y = -0.4 },
};

const ALIEN_BODY = [_]Vector2{
    .{ .x = -0.5, .y = 0.0 },
    .{ .x = -0.3, .y = 0.3 },
    .{ .x = 0.3, .y = 0.3 },
    .{ .x = 0.5, .y = 0.0 },
    .{ .x = 0.3, .y = -0.3 },
    .{ .x = -0.3, .y = -0.3 },
    .{ .x = -0.5, .y = 0.0 },
    .{ .x = 0.5, .y = 0.0 },
};

const ALIEN_ANTENNA = [_]Vector2{
    .{ .x = -0.2, .y = -0.3 },
    .{ .x = -0.1, .y = -0.5 },
    .{ .x = 0.1, .y = -0.5 },
    .{ .x = 0.2, .y = -0.3 },
};

// ── Game state ────────────────────────────────────────────────────

const Game = struct {
    now: f32 = 0,
    delta: f32 = 0,
    stage_start: f32 = 0,
    ship: Ship,
    asteroids: std.ArrayList(Asteroid),
    asteroids_queue: std.ArrayList(Asteroid),
    projectiles: std.ArrayList(Projectile),
    aliens: std.ArrayList(Alien),
    rand: Random,
    allocator: std.mem.Allocator,
    lives: usize = 0,
    last_score: usize = 0,
    score: usize = 0,
    last_bloop: usize = 0,
    bloop: usize = 0,
    frame: usize = 0,
    qrc: u32 = QUANTUM_REMATERIZATION_LIMIT,
    bonus_ship_score: usize = 10000,
    paused: bool = false,
    shield_active: bool = false,
    shield_activate_time: f32 = 0.0,
    shield_ready_time: f32 = 0.0,
    game_over: bool = false,
    last_berzerk_coin_time: f32 = 0.0,
    shots_fired: usize = 0,
    shots_hit: usize = 0,
    aliens_killed: usize = 0,
    alien_kills: usize = 0,
    field: usize = 1,
};

fn shieldRadius(scale: f32) f32 {
    return scale * 1.5;
}

// ── Drawing helpers ───────────────────────────────────────────────

fn drawAsteroid(ctx: *const vgame.RenderContext, pos: Vector2, size: AsteroidSize, seed: u64, scale: f32) void {
    var prng = std.Random.Xoshiro256.init(seed);
    var random = prng.random();

    var buffer: [16]Vector2 = undefined;
    var points = std.ArrayListUnmanaged(Vector2).initBuffer(&buffer);
    const n = random.intRangeLessThan(i32, 8, 15);

    for (0..@intCast(n)) |i| {
        var radius = 0.3 + (0.2 * random.float(f32));
        if (random.float(f32) < 0.2) {
            radius -= 0.2;
        }
        const angle: f32 = (@as(f32, @floatFromInt(i)) * (math.tau / @as(f32, @floatFromInt(n)))) +
            (math.pi * 0.125 * random.float(f32));
        points.appendAssumeCapacity(
            rlm.vector2Scale(.{ .x = math.cos(angle), .y = math.sin(angle) }, radius),
        );
    }

    ctx.drawLines(pos, size.drawSize(scale), 0.0, points.items, true, rl.Color.ray_white);
}

fn drawAlien(ctx: *const vgame.RenderContext, pos: Vector2, size: AlienSize, scale: f32) void {
    const s: f32 = switch (size) {
        .BIG => 1.0,
        .SMALL => 0.5,
    };
    ctx.drawLines(pos, scale * s, 0, &ALIEN_BODY, false, rl.Color.green);
    ctx.drawLines(pos, scale * s, 0, &ALIEN_ANTENNA, false, rl.Color.green);
}

// Quantum rematerialization color: purple -> white as ship phases in
fn qrcColor(qrc: u32) rl.Color {
    if (qrc == 0) return rl.Color.white;
    const pct: f32 = 1.0 - @as(f32, @floatFromInt(qrc)) / @as(f32, @floatFromInt(QUANTUM_REMATERIZATION_LIMIT));
    return vgame.lerpColor(rl.Color.purple, rl.Color.white, pct);
}

fn alienRatioStr(buf: *[128:0]u8, aliens_killed: usize, alien_kills: usize) [:0]const u8 {
    if (aliens_killed == 0 and alien_kills == 0) {
        return std.fmt.bufPrintZ(buf, "No alien encounters", .{}) catch unreachable;
    }
    if (aliens_killed > alien_kills) {
        if (alien_kills == 0) {
            return std.fmt.bufPrintZ(buf, "{d} to 0 ratio alien kill ratio", .{aliens_killed}) catch unreachable;
        }
        const ratio: f32 = @as(f32, @floatFromInt(aliens_killed)) / @as(f32, @floatFromInt(alien_kills));
        return std.fmt.bufPrintZ(buf, "{d:.1} to 1 ratio alien kill ratio", .{ratio}) catch unreachable;
    } else if (alien_kills > aliens_killed) {
        if (aliens_killed == 0) {
            return std.fmt.bufPrintZ(buf, "0 to {d} rate player vs. alien death ratio", .{alien_kills}) catch unreachable;
        }
        const ratio: f32 = @as(f32, @floatFromInt(alien_kills)) / @as(f32, @floatFromInt(aliens_killed));
        return std.fmt.bufPrintZ(buf, "1 to {d:.1} rate player vs. alien death ratio", .{ratio}) catch unreachable;
    } else {
        return std.fmt.bufPrintZ(buf, "1 to 1 ratio", .{}) catch unreachable;
    }
}

// ── Overlays ──────────────────────────────────────────────────────

fn drawHelpBox(g: *const Game, input: *const vgame.InputManager, field_size: Vector2) void {
    const lines = [_][:0]const u8{
        "Large Space Rocks",
        "",
        "LEFT/RIGHT  Rotate",
        "UP/W        Thrust",
        "DOWN        Shields",
        "SPACE/CLICK Shoot",
        "H / P       Pause",
        "1           New Game",
        "F           Fullscreen",
    };

    const gamepad_lines = [_][:0]const u8{
        "",
        "Gamepad",
        "LS / D-PAD  Rotate",
        "RT / X      Thrust",
        "B / LT      Shields",
        "A           Shoot",
        "Start       Pause",
    };

    const font_size: i32 = 30;
    const line_spacing: i32 = 10;
    const padding: i32 = 40;
    const total_line_height = font_size + line_spacing;
    const show_gamepad = input.isGamepadConnected();
    const gamepad_line_count: i32 = if (show_gamepad) @intCast(gamepad_lines.len) else 1;
    const stats_lines: i32 = 3;
    const panel_width: f32 = 520;
    const panel_height: f32 = @floatFromInt(
        @as(i32, @intCast(lines.len)) * total_line_height +
            gamepad_line_count * total_line_height +
            stats_lines * total_line_height + padding * 2,
    );

    const panel_x = (field_size.x - panel_width) / 2;
    const panel_y = (field_size.y - panel_height) / 2;

    rl.drawRectangleRec(.{ .x = panel_x, .y = panel_y, .width = panel_width, .height = panel_height }, vgame.rgba(16, 60, 140, 200));
    rl.drawRectangleLinesEx(.{ .x = panel_x, .y = panel_y, .width = panel_width, .height = panel_height }, 2, vgame.rgba(80, 160, 255, 220));

    const text_color = rl.Color.white;
    var y: i32 = @as(i32, @intFromFloat(panel_y)) + padding;
    for (lines) |line| {
        const tw = rl.measureText(line, font_size);
        const x: i32 = @as(i32, @intFromFloat(panel_x + (panel_width - @as(f32, @floatFromInt(tw))) / 2));
        rl.drawText(line, x, y, font_size, text_color);
        y += total_line_height;
    }

    if (show_gamepad) {
        for (gamepad_lines) |line| {
            const tw = rl.measureText(line, font_size);
            const x: i32 = @as(i32, @intFromFloat(panel_x + (panel_width - @as(f32, @floatFromInt(tw))) / 2));
            rl.drawText(line, x, y, font_size, text_color);
            y += total_line_height;
        }
    }

    // "PAUSED" label
    {
        const paused_text: [:0]const u8 = "PAUSED";
        const tw = rl.measureText(paused_text, font_size);
        const x: i32 = @as(i32, @intFromFloat(panel_x + (panel_width - @as(f32, @floatFromInt(tw))) / 2));
        rl.drawText(paused_text, x, y, font_size, text_color);
        y += total_line_height;
    }

    // Stats section
    {
        y += total_line_height; // blank line
        const accuracy: usize = if (g.shots_fired > 0) (g.shots_hit * 100) / g.shots_fired else 0;
        var acc_buf: [64:0]u8 = undefined;
        const acc_str = std.fmt.bufPrintZ(&acc_buf, "Accuracy: {d}%", .{accuracy}) catch unreachable;
        const acc_w = rl.measureText(acc_str, font_size);
        const acc_x: i32 = @as(i32, @intFromFloat(panel_x + (panel_width - @as(f32, @floatFromInt(acc_w))) / 2));
        rl.drawText(acc_str, acc_x, y, font_size, text_color);
        y += total_line_height;

        var kill_buf: [128:0]u8 = undefined;
        const kill_str = alienRatioStr(&kill_buf, g.aliens_killed, g.alien_kills);
        const kill_w = rl.measureText(kill_str, font_size);
        const kill_x: i32 = @as(i32, @intFromFloat(panel_x + (panel_width - @as(f32, @floatFromInt(kill_w))) / 2));
        rl.drawText(kill_str, kill_x, y, font_size, text_color);
    }
}

fn drawGameOverBox(g: *const Game, input: *const vgame.InputManager, field_size: Vector2) void {
    // Translucent dark overlay
    rl.drawRectangleRec(.{ .x = 0, .y = 0, .width = field_size.x, .height = field_size.y }, vgame.rgba(0, 0, 0, 140));

    const title = "..  game over  ..";
    const score_label = "Final Score";
    var score_buf: [32:0]u8 = undefined;
    const score_str = std.fmt.bufPrintZ(&score_buf, "{d}", .{g.score}) catch return;
    const coin_text = "Coin detected in pocket";
    const restart_hint: [:0]const u8 = if (input.isGamepadConnected())
        "Press 1 or Start to start a new game"
    else
        "Press 1 to start a new game";

    const font_size: i32 = 40;
    const small_font_size: i32 = 28;
    const line_spacing: i32 = 12;
    const padding: i32 = 50;
    const total_line_height = font_size + line_spacing;
    const small_line_height = small_font_size + line_spacing;

    const panel_width: f32 = 520;
    const panel_height: f32 = @floatFromInt(
        total_line_height + 20 + small_line_height + small_line_height + 20 +
            small_line_height + small_line_height + 10 + small_line_height +
            small_line_height + small_line_height + small_line_height + padding * 2,
    );

    const panel_x = (field_size.x - panel_width) / 2;
    const panel_y = (field_size.y - panel_height) / 2;

    rl.drawRectangleRec(.{ .x = panel_x, .y = panel_y, .width = panel_width, .height = panel_height }, vgame.rgba(80, 16, 16, 200));
    rl.drawRectangleLinesEx(.{ .x = panel_x, .y = panel_y, .width = panel_width, .height = panel_height }, 2, vgame.rgba(220, 80, 80, 220));

    var y: i32 = @as(i32, @intFromFloat(panel_y)) + padding;

    // Title
    {
        const tw = rl.measureText(title, font_size);
        const x: i32 = @as(i32, @intFromFloat(panel_x + (panel_width - @as(f32, @floatFromInt(tw))) / 2));
        rl.drawText(title, x, y, font_size, rl.Color.red);
        y += total_line_height + 20;
    }
    // Final score label
    {
        const tw = rl.measureText(score_label, small_font_size);
        const x: i32 = @as(i32, @intFromFloat(panel_x + (panel_width - @as(f32, @floatFromInt(tw))) / 2));
        rl.drawText(score_label, x, y, small_font_size, rl.Color.gray);
        y += small_line_height;
    }
    // Score value
    {
        const tw = rl.measureText(score_str, small_font_size);
        const x: i32 = @as(i32, @intFromFloat(panel_x + (panel_width - @as(f32, @floatFromInt(tw))) / 2));
        rl.drawText(score_str, x, y, small_font_size, rl.Color.white);
        y += small_line_height + 20;
    }
    // Stats
    {
        const accuracy: usize = if (g.shots_fired > 0) (g.shots_hit * 100) / g.shots_fired else 0;
        var acc_buf: [64:0]u8 = undefined;
        const acc_str = std.fmt.bufPrintZ(&acc_buf, "Accuracy: {d}%", .{accuracy}) catch unreachable;
        const acc_w = rl.measureText(acc_str, small_font_size);
        const acc_x: i32 = @as(i32, @intFromFloat(panel_x + (panel_width - @as(f32, @floatFromInt(acc_w))) / 2));
        rl.drawText(acc_str, acc_x, y, small_font_size, rl.Color.gray);
        y += small_line_height;

        var kill_buf: [128:0]u8 = undefined;
        const kill_str = alienRatioStr(&kill_buf, g.aliens_killed, g.alien_kills);
        const kill_w = rl.measureText(kill_str, small_font_size);
        const kill_x: i32 = @as(i32, @intFromFloat(panel_x + (panel_width - @as(f32, @floatFromInt(kill_w))) / 2));
        rl.drawText(kill_str, kill_x, y, small_font_size, rl.Color.gray);
        y += small_line_height + 10;
    }
    // "Coin detected in pocket" — slowly fades in and out
    {
        const coin_pulse: f32 = 0.5 + 0.5 * @sin(g.now * math.tau * 0.3);
        const coin_alpha: u8 = @as(u8, @intFromFloat(30 + coin_pulse * 225));
        const coin_color = vgame.rgba(255, 220, 100, coin_alpha);
        const tw = rl.measureText(coin_text, small_font_size);
        const x: i32 = @as(i32, @intFromFloat(panel_x + (panel_width - @as(f32, @floatFromInt(tw))) / 2));
        rl.drawText(coin_text, x, y, small_font_size, coin_color);
        y += small_line_height;
    }
    // "Press 1 to start a new game" — pulsating
    {
        const pulse: f32 = 0.5 + 0.5 * @sin(g.now * math.tau * 0.8);
        const hint_alpha: u8 = @as(u8, @intFromFloat(120 + pulse * 135));
        const hint_color = vgame.rgba(255, 255, 255, hint_alpha);
        const tw = rl.measureText(restart_hint, small_font_size);
        const x: i32 = @as(i32, @intFromFloat(panel_x + (panel_width - @as(f32, @floatFromInt(tw))) / 2));
        rl.drawText(restart_hint, x, y, small_font_size, hint_color);
        y += small_line_height;
    }
    // "Press help" with yellow 'h'
    {
        const pulse: f32 = 0.5 + 0.5 * @sin(g.now * math.tau * 0.8);
        const hint_alpha: u8 = @as(u8, @intFromFloat(120 + pulse * 135));
        const normal_color = vgame.rgba(255, 255, 255, hint_alpha);
        const yellow_color = vgame.rgba(255, 255, 0, hint_alpha);

        const help_prefix = "Press ";
        const help_highlight = "h";
        const help_suffix = "elp";
        const full_text = "Press help";
        const full_w = rl.measureText(full_text, small_font_size);
        const start_x: i32 = @as(i32, @intFromFloat(panel_x + (panel_width - @as(f32, @floatFromInt(full_w))) / 2));

        rl.drawText(help_prefix, start_x, y, small_font_size, normal_color);
        const prefix_w = rl.measureText(help_prefix, small_font_size);
        rl.drawText(help_highlight, start_x + prefix_w, y, small_font_size, yellow_color);
        const highlight_w = rl.measureText(help_highlight, small_font_size);
        rl.drawText(help_suffix, start_x + prefix_w + highlight_w, y, small_font_size, normal_color);
    }
}

// ── Game logic ────────────────────────────────────────────────────

fn hitAsteroid(g: *Game, a: *Asteroid, impact: ?Vector2, audio: *const vgame.AudioManager, particles: *vgame.Particles, scale: f32) !void {
    audio.play(@intFromEnum(SFX.asteroid));
    g.score += a.size.score();
    a.remove = true;

    try particles.spawnDots(a.pos, 10, .{ .color = rl.Color.white, .scale = scale }, &g.rand);

    if (a.size == .SMALL) return;

    for (0..2) |_| {
        const dir = rlm.vector2Normalize(a.vel);
        const size: AsteroidSize = switch (a.size) {
            .BIG => .MEDIUM,
            .MEDIUM => .SMALL,
            else => unreachable,
        };
        try g.asteroids_queue.append(g.allocator, .{
            .pos = a.pos,
            .vel = rlm.vector2Add(
                rlm.vector2Scale(dir, a.size.velocityScale() * 2.2 * g.rand.float(f32)),
                if (impact) |i| rlm.vector2Scale(i, 0.7) else .{ .x = 0, .y = 0 },
            ),
            .size = size,
            .seed = g.rand.int(u64),
        });
    }
}

fn update(g: *Game, input: *const vgame.InputManager, audio: *const vgame.AudioManager, particles: *vgame.Particles, scale: f32, field_size: Vector2) !void {
    // Pause/unpause (disabled during game over)
    if (!g.paused and !g.game_over) {
        if (input.isPressed(@intFromEnum(Action.pause)) or rl.isKeyPressed(.p)) {
            g.paused = true;
        }
    } else if (g.paused) {
        if (input.isPressed(@intFromEnum(Action.pause)) or rl.isKeyPressed(.space) or rl.isKeyPressed(.p)) {
            g.paused = false;
        }
        return;
    }

    // Game over screen
    if (g.game_over) {
        if (input.isPressed(@intFromEnum(Action.new_game))) {
            g.game_over = false;
            try resetGame(g, field_size);
        } else if ((g.now - g.last_berzerk_coin_time) >= BERZERK_COIN_INTERVAL) {
            std.debug.print("Coin detected in pocket!\n", .{});
            audio.play(@intFromEnum(SFX.berzerk_coin));
            g.last_berzerk_coin_time = g.now;
        }
        // Skip ship control but continue updating asteroids/particles/aliens
    }

    // Shield activation
    if (!g.ship.isDead() and !g.shield_active and g.now >= g.shield_ready_time) {
        if (input.isPressed(@intFromEnum(Action.shield))) {
            g.shield_active = true;
            g.shield_activate_time = g.now;
        }
    }
    // Shield expiry
    if (g.shield_active and (g.now - g.shield_activate_time) > SHIELD_DURATION) {
        g.shield_active = false;
        g.shield_ready_time = g.now + SHIELD_RECHARGE;
    }

    if (!g.ship.isDead() and !g.game_over) {
        if (g.qrc > 0) {
            g.qrc -= 1;
        }

        const ROT_SPEED = 2;
        const SHIP_SPEED = 24;

        const rot = input.rotationAmount();
        g.ship.rot += g.delta * math.tau * ROT_SPEED * rot;

        const dir_angle = g.ship.rot + (math.pi * 0.5);
        const ship_dir = Vector2.init(math.cos(dir_angle), math.sin(dir_angle));

        // Thrust: also check 'w' key directly since vgame bindings only map one key per action
        if (input.isDown(@intFromEnum(Action.thrust)) or rl.isKeyDown(.w)) {
            g.ship.vel = rlm.vector2Add(g.ship.vel, rlm.vector2Scale(ship_dir, g.delta * SHIP_SPEED));
            if (g.frame % 2 == 0) {
                audio.play(@intFromEnum(SFX.thrust));
            }
        }

        const DRAG = 0.015;
        g.ship.vel = rlm.vector2Scale(g.ship.vel, 1.0 - DRAG);
        g.ship.pos = rlm.vector2Add(g.ship.pos, g.ship.vel);
        g.ship.pos = vgame.wrapPos(g.ship.pos, field_size);

        // Shoot: also check mouse click
        if (input.isPressed(@intFromEnum(Action.shoot)) or rl.isMouseButtonPressed(.left)) {
            try g.projectiles.append(g.allocator, .{
                .pos = rlm.vector2Add(g.ship.pos, rlm.vector2Scale(ship_dir, scale * 0.55)),
                .vel = rlm.vector2Scale(ship_dir, 10.0),
                .ttl = 2.0,
                .spawn = g.now,
                .player = true,
            });
            audio.play(@intFromEnum(SFX.shoot));
            g.shots_fired += 1;
            g.ship.vel = rlm.vector2Add(g.ship.vel, rlm.vector2Scale(ship_dir, -0.25));
        }

        // Alien bullet vs ship collision
        for (g.projectiles.items) |*p| {
            if (!p.player and !p.remove and g.qrc == 0) {
                if ((g.now - p.spawn) > 0.15 and rlm.vector2Distance(g.ship.pos, p.pos) < (scale * 0.7)) {
                    if (g.shield_active and rlm.vector2Distance(g.ship.pos, p.pos) < shieldRadius(scale)) {
                        p.remove = true;
                    } else {
                        p.remove = true;
                        g.ship.death_time = g.now;
                        g.alien_kills += 1;
                    }
                }
            }
        }
    }

    // Add queued asteroids
    for (g.asteroids_queue.items) |a| {
        try g.asteroids.append(g.allocator, a);
    }
    try g.asteroids_queue.resize(g.allocator, 0);

    // Update asteroids
    {
        var i: usize = 0;
        while (i < g.asteroids.items.len) {
            var a = &g.asteroids.items[i];
            a.pos = rlm.vector2Add(a.pos, a.vel);
            a.pos = vgame.wrapPos(a.pos, field_size);

            // Ship vs asteroid
            if (!a.remove and g.qrc == 0 and !g.ship.isDead() and
                rlm.vector2Distance(a.pos, g.ship.pos) < a.size.drawSize(scale) * a.size.collisionScale())
            {
                if (g.shield_active and rlm.vector2Distance(a.pos, g.ship.pos) < shieldRadius(scale)) {
                    try hitAsteroid(g, a, rlm.vector2Normalize(g.ship.vel), audio, particles, scale);
                } else {
                    g.ship.death_time = g.now;
                    try hitAsteroid(g, a, rlm.vector2Normalize(g.ship.vel), audio, particles, scale);
                }
            }

            // Alien vs asteroid
            for (g.aliens.items) |*l| {
                if (!a.remove and !l.remove and rlm.vector2Distance(a.pos, l.pos) < a.size.drawSize(scale) * a.size.collisionScale()) {
                    l.remove = true;
                    try hitAsteroid(g, a, rlm.vector2Normalize(g.ship.vel), audio, particles, scale);
                }
            }

            // Projectile vs asteroid
            for (g.projectiles.items) |*p| {
                if (!a.remove and !p.remove and rlm.vector2Distance(a.pos, p.pos) < a.size.drawSize(scale) * a.size.collisionScale()) {
                    p.remove = true;
                    if (p.player) g.shots_hit += 1;
                    try hitAsteroid(g, a, rlm.vector2Normalize(p.vel), audio, particles, scale);
                }
            }

            if (a.remove) {
                _ = g.asteroids.swapRemove(i);
            } else {
                i += 1;
            }
        }
    }

    // Update projectiles
    {
        var i: usize = 0;
        while (i < g.projectiles.items.len) {
            var p = &g.projectiles.items[i];
            p.pos = rlm.vector2Add(p.pos, p.vel);
            p.pos = vgame.wrapPos(p.pos, field_size);

            if (!p.remove and p.ttl > g.delta) {
                p.ttl -= g.delta;
                i += 1;
            } else {
                _ = g.projectiles.swapRemove(i);
            }
        }
    }

    // Update aliens
    {
        var i: usize = 0;
        while (i < g.aliens.items.len) {
            var a = &g.aliens.items[i];

            // Projectile vs alien
            for (g.projectiles.items) |*p| {
                if (!p.remove and (g.now - p.spawn) > 0.15 and rlm.vector2Distance(a.pos, p.pos) < a.size.collisionSize(scale)) {
                    p.remove = true;
                    a.remove = true;
                    if (p.player) {
                        g.shots_hit += 1;
                        g.aliens_killed += 1;
                    }
                }
            }

            // Alien vs ship
            if (!a.remove and rlm.vector2Distance(a.pos, g.ship.pos) < a.size.collisionSize(scale)) {
                if (g.shield_active and rlm.vector2Distance(a.pos, g.ship.pos) < shieldRadius(scale)) {
                    a.remove = true;
                } else if (!g.ship.isDead()) {
                    a.remove = true;
                    g.ship.death_time = g.now;
                    g.alien_kills += 1;
                }
            }

            if (!a.remove) {
                if ((g.now - a.last_dir) > a.size.dirChangeTime()) {
                    a.last_dir = g.now;
                    const angle = math.tau * g.rand.float(f32);
                    a.dir = Vector2.init(math.cos(angle), math.sin(angle));
                }

                a.pos = rlm.vector2Add(a.pos, rlm.vector2Scale(a.dir, a.size.speed()));
                a.pos = vgame.wrapPos(a.pos, field_size);

                if ((g.now - a.last_shot) > a.size.shotTime() + 4 * g.rand.float(f32)) {
                    a.last_shot = g.now;
                    const dir = rlm.vector2Normalize(rlm.vector2Subtract(g.ship.pos, a.pos));
                    try g.projectiles.append(g.allocator, .{
                        .pos = rlm.vector2Add(a.pos, rlm.vector2Scale(dir, scale * 0.55)),
                        .vel = rlm.vector2Scale(dir, 6.0),
                        .ttl = 2.0,
                        .spawn = g.now,
                    });
                    audio.play(@intFromEnum(SFX.shoot));
                }
            }

            if (a.remove) {
                audio.play(@intFromEnum(SFX.asteroid));
                try particles.spawnDots(a.pos, 15, .{ .color = rl.Color.green, .scale = scale }, &g.rand);
                try particles.spawnLines(a.pos, 4, .{ .color = rl.Color.green, .scale = scale }, &g.rand);
                _ = g.aliens.swapRemove(i);
            } else {
                i += 1;
            }
        }
    }

    // Ship death explosion
    if (g.ship.death_time == g.now) {
        audio.play(@intFromEnum(SFX.explode));
        try particles.spawnDots(g.ship.pos, 20, .{ .color = rl.Color.white, .scale = scale }, &g.rand);
        try particles.spawnLines(g.ship.pos, 5, .{ .color = rl.Color.white, .scale = scale }, &g.rand);
    }

    // Respawn after death
    if (g.ship.isDead() and (g.now - g.ship.death_time) > 3.0) {
        if (g.lives == 0) {
            if (!g.game_over) {
                g.game_over = true;
                g.last_berzerk_coin_time = g.now;
            }
        } else {
            try resetStage(g, field_size);
        }
    }

    // Heartbeat bloop
    const bloop_intensity = @min(@as(usize, @intFromFloat(g.now - g.stage_start)) / 15, 3);
    var bloop_mod: usize = 60;
    for (0..bloop_intensity) |_| {
        bloop_mod /= 2;
    }
    if (g.frame % bloop_mod == 0) g.bloop += 1;
    if (!g.ship.isDead() and g.bloop != g.last_bloop) {
        audio.play(if (g.bloop % 2 == 1) @intFromEnum(SFX.bloop_hi) else @intFromEnum(SFX.bloop_lo));
    }
    g.last_bloop = g.bloop;

    // Field transition: all asteroids destroyed
    if (!g.game_over and g.asteroids.items.len == 0 and g.asteroids_queue.items.len == 0) {
        try resetAsteroids(g, field_size);
    }

    // Spawn big alien every 5000 points
    if ((g.last_score / 5000) != (g.score / 5000)) {
        try g.aliens.append(g.allocator, .{
            .pos = .{
                .x = if (g.rand.boolean()) 0 else field_size.x - scale,
                .y = g.rand.float(f32) * field_size.y,
            },
            .dir = .{ .x = 0, .y = 0 },
            .size = .BIG,
        });
    }

    // Spawn small alien every 8000 points
    if ((g.last_score / 8000) != (g.score / 8000)) {
        try g.aliens.append(g.allocator, .{
            .pos = .{
                .x = if (g.rand.boolean()) 0 else field_size.x - scale,
                .y = g.rand.float(f32) * field_size.y,
            },
            .dir = .{ .x = 0, .y = 0 },
            .size = .SMALL,
        });
    }

    // Bonus ships
    if (g.score > g.bonus_ship_score) {
        g.lives += 1;
        g.bonus_ship_score += 10000;
    }

    g.last_score = g.score;
}

fn render(g: *const Game, ctx: *const vgame.RenderContext, input: *const vgame.InputManager, particles: *const vgame.Particles, scale: f32, field_size: Vector2) void {
    // Remaining lives
    for (0..g.lives) |i| {
        ctx.drawLines(
            .{ .x = scale + (@as(f32, @floatFromInt(i)) * scale), .y = scale },
            scale,
            -math.pi,
            &SHIP_LINES,
            true,
            rl.Color.white,
        );
    }

    // Field number
    {
        var field_buf: [32:0]u8 = undefined;
        const field_str = std.fmt.bufPrintZ(&field_buf, "Field {d}", .{g.field}) catch unreachable;
        const field_font: i32 = 20;
        const tw = rl.measureText(field_str, field_font);
        const fx: i32 = @as(i32, @intFromFloat((field_size.x - @as(f32, @floatFromInt(tw))) / 2));
        const fy: i32 = @as(i32, @intFromFloat(scale * 0.3));
        rl.drawText(field_str, fx, fy, field_font, rl.Color.white);
    }

    // Score
    ctx.drawNumberColored(g.score, .{ .x = field_size.x - scale, .y = scale }, rl.Color.white);

    // Ship
    if (!g.ship.isDead()) {
        const ship_color = qrcColor(g.qrc);
        ctx.drawLines(g.ship.pos, scale, g.ship.rot, &SHIP_LINES, true, ship_color);

        // Thrust flame
        if ((input.isDown(@intFromEnum(Action.thrust)) or rl.isKeyDown(.w)) and
            @mod(@as(i32, @intFromFloat(g.now * 20)), 2) == 0)
        {
            ctx.drawLines(g.ship.pos, scale, g.ship.rot, &THRUST_LINES, true, rl.Color.ray_white);
        }
    }

    // Asteroids
    for (g.asteroids.items) |a| {
        drawAsteroid(ctx, a.pos, a.size, a.seed, scale);
    }

    // Aliens
    for (g.aliens.items) |a| {
        drawAlien(ctx, a.pos, a.size, scale);
    }

    // Particles
    particles.render();

    // Projectiles
    for (g.projectiles.items) |p| {
        const bullet_color: rl.Color = if (p.player) rl.Color.white else rl.Color.green;
        rl.drawCircleV(p.pos, @max(scale * 0.05, 1), bullet_color);
    }

    // Shield circle
    if (g.shield_active and !g.ship.isDead()) {
        const elapsed = g.now - g.shield_activate_time;
        const pulse = 0.6 + 0.4 * @sin(elapsed * math.tau * 8);
        rl.drawCircleV(g.ship.pos, shieldRadius(scale), vgame.rgba(180, 0, 255, @as(u8, @intFromFloat(pulse * 220))));
        rl.drawCircleLinesV(g.ship.pos, shieldRadius(scale), vgame.rgba(220, 100, 255, @as(u8, @intFromFloat(pulse * 255))));
    }

    // Quantum phase-in border
    if (!g.ship.isDead() and g.qrc > 0) {
        const qrc_pct: f32 = 1.0 - @as(f32, @floatFromInt(g.qrc)) / @as(f32, @floatFromInt(QUANTUM_REMATERIZATION_LIMIT));
        const fade: f32 = 1.0 - qrc_pct;
        const max_margin: f32 = 30;
        const margin = max_margin * fade;
        const border_alpha: u8 = @as(u8, @intFromFloat(fade * 190));
        const border_color = vgame.rgba(180, 0, 255, border_alpha);
        rl.drawRectangleRec(.{ .x = 0, .y = 0, .width = field_size.x, .height = margin }, border_color);
        rl.drawRectangleRec(.{ .x = 0, .y = field_size.y - margin, .width = field_size.x, .height = margin }, border_color);
        rl.drawRectangleRec(.{ .x = 0, .y = margin, .width = margin, .height = field_size.y - margin * 2 }, border_color);
        rl.drawRectangleRec(.{ .x = field_size.x - margin, .y = margin, .width = margin, .height = field_size.y - margin * 2 }, border_color);
    }

    // Shield recharge border
    if (!g.ship.isDead() and !g.shield_active and g.shield_ready_time > g.now and g.shield_ready_time > 0) {
        const elapsed = g.now - (g.shield_ready_time - SHIELD_RECHARGE);
        const progress = @min(elapsed / SHIELD_RECHARGE, 1.0);
        const max_margin: f32 = 30;
        const margin = max_margin * progress;
        const border_alpha: u8 = @as(u8, @intFromFloat(progress * 150 + 40));
        const border_color = vgame.rgba(180, 0, 255, border_alpha);
        rl.drawRectangleRec(.{ .x = 0, .y = 0, .width = field_size.x, .height = margin }, border_color);
        rl.drawRectangleRec(.{ .x = 0, .y = field_size.y - margin, .width = field_size.x, .height = margin }, border_color);
        rl.drawRectangleRec(.{ .x = 0, .y = margin, .width = margin, .height = field_size.y - margin * 2 }, border_color);
        rl.drawRectangleRec(.{ .x = field_size.x - margin, .y = margin, .width = margin, .height = field_size.y - margin * 2 }, border_color);
    }

    // Overlays
    if (g.paused) {
        drawHelpBox(g, input, field_size);
    }
    if (g.game_over) {
        drawGameOverBox(g, input, field_size);
    }
}

// ── Reset functions ───────────────────────────────────────────────

fn resetAsteroids(g: *Game, field_size: Vector2) !void {
    try g.asteroids.resize(g.allocator, 0);

    // Clear alien projectiles (but keep aliens)
    {
        var i: usize = 0;
        while (i < g.projectiles.items.len) {
            if (!g.projectiles.items[i].player) {
                _ = g.projectiles.swapRemove(i);
            } else {
                i += 1;
            }
        }
    }

    const min_dist_x = field_size.x / @as(f32, @floatFromInt(FIELD_GRID_DIV));
    const min_dist_y = field_size.y / @as(f32, @floatFromInt(FIELD_GRID_DIV));

    for (0..(15 + g.score / 1500)) |_| {
        const angle = math.tau * g.rand.float(f32);
        const size = g.rand.enumValue(AsteroidSize);

        var pos = Vector2.init(0, 0);
        while (true) {
            pos = .{
                .x = g.rand.float(f32) * field_size.x,
                .y = g.rand.float(f32) * field_size.y,
            };
            const dx = if (pos.x > g.ship.pos.x) pos.x - g.ship.pos.x else g.ship.pos.x - pos.x;
            const dy = if (pos.y > g.ship.pos.y) pos.y - g.ship.pos.y else g.ship.pos.y - pos.y;
            if (!(dx < min_dist_x and dy < min_dist_y)) break;
        }

        try g.asteroids_queue.append(g.allocator, .{
            .pos = pos,
            .vel = rlm.vector2Scale(
                Vector2.init(math.cos(angle), math.sin(angle)),
                size.velocityScale() * 3.0 * g.rand.float(f32),
            ),
            .size = size,
            .seed = g.rand.int(u64),
        });
    }

    g.stage_start = g.now;
    g.field += 1;
}

fn resetGame(g: *Game, field_size: Vector2) !void {
    g.lives = 3;
    g.score = 0;
    g.bonus_ship_score = 10000;
    g.shots_fired = 0;
    g.shots_hit = 0;
    g.aliens_killed = 0;
    g.alien_kills = 0;
    g.field = 0;
    g.ship.death_time = 0.0;
    g.qrc = QUANTUM_REMATERIZATION_LIMIT;
    g.shield_active = false;
    g.shield_ready_time = 0.0;

    try resetStage(g, field_size);
    try resetAsteroids(g, field_size);
}

fn resetStage(g: *Game, field_size: Vector2) !void {
    if (g.ship.isDead()) {
        if (g.lives == 0) {
            // Game over triggered from update()
        } else {
            g.qrc = QUANTUM_REMATERIZATION_LIMIT;
            g.lives -= 1;
        }
    }

    g.ship.death_time = 0.0;
    g.ship = .{
        .pos = rlm.vector2Scale(field_size, 0.5),
        .vel = .{ .x = 0, .y = 0 },
        .rot = 0.0,
    };
}

// ── Main ──────────────────────────────────────────────────────────

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    // Parse command-line arguments
    var start_fullscreen = false;
    {
        var args = try std.process.argsAlloc(allocator);
        defer std.process.argsFree(allocator, args);
        for (args[1..]) |arg| {
            if (std.mem.eql(u8, arg, "-f")) start_fullscreen = true;
            if (std.mem.eql(u8, arg, "-w")) start_fullscreen = false;
            if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
                const usage =
                    \\Large Space Rocks (zigsteroids2)
                    \\
                    \\Usage: zigsteroids2 [OPTIONS]
                    \\
                    \\Options:
                    \\  -f          Start in fullscreen mode
                    \\  -w          Start in windowed mode (default)
                    \\  -h, --help  Show this help message and exit
                    \\
                    \\In-game controls:
                    \\  LEFT/RIGHT  Rotate ship
                    \\  UP / W      Thrust
                    \\  DOWN        Shields
                    \\  SPACE/CLICK Shoot
                    \\  H / P       Pause / Help
                    \\  1           New Game
                    \\  F           Toggle fullscreen
                    \\
                ;
                std.debug.print("{s}\n", .{usage});
                return;
            }
        }
    }

    // Initialize the vgame platform
    var app = try vgame.App.init(allocator, .{
        .title = "LARGE SPACE ROCKS",
        .design_size = .{ .x = 1280, .y = 960 },
        .base_scale = 38.0,
        .fullscreen = start_fullscreen,
    });
    defer app.deinit();

    // Initialize audio
    try app.initAudio(.{
        .clips = &sound_clips,
        .resource_dir = "resources",
    });
    const audio = &app.audio.?;

    // Initialize input
    var input = vgame.InputManager.init(allocator, &bindings, action_count);
    defer input.deinit();

    // Initialize particles
    var particles = vgame.Particles.init(allocator);
    defer particles.deinit();

    // PRNG
    var prng = std.Random.Xoshiro256.init(@bitCast(std.time.timestamp()));

    var game = Game{
        .ship = .{
            .pos = rlm.vector2Scale(app.screen.size, 0.5),
            .vel = .{ .x = 0, .y = 0 },
            .rot = 0.0,
        },
        .asteroids = .empty,
        .asteroids_queue = .empty,
        .projectiles = .empty,
        .aliens = .empty,
        .rand = prng.random(),
        .allocator = allocator,
        .qrc = QUANTUM_REMATERIZATION_LIMIT,
    };
    defer game.asteroids.deinit(allocator);
    defer game.asteroids_queue.deinit(allocator);
    defer game.projectiles.deinit(allocator);
    defer game.aliens.deinit(allocator);

    try resetGame(&game, app.screen.size);

    // Main loop
    while (app.frame()) {
        game.delta = app.delta;
        game.now = app.time;
        const scale = app.screen.scale;
        const field_size = app.screen.size;

        input.update();
        particles.update(game.delta, field_size);

        try update(&game, &input, audio, &particles, scale, field_size);

        var ctx = app.beginRender();
        defer ctx.end();

        render(&game, &ctx, &input, &particles, scale, field_size);
        game.frame += 1;
    }
}