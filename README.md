# Zigsteroids 2

A Zig implementation of the classic 1979 Atari arcade game **Asteroids** -- or as the title screen calls it, _LARGE SPACE ROCKS_.

This is a rewrite of [zigsteroids](https://github.com/rseward/zigsteroids) built on the [zigvectorgames](https://github.com/rseward/zigvectorgames) (vgame) platform. The original game had its own inline code for window management, screen scaling, input handling, audio loading, particle systems, and vector rendering. Zigsteroids 2 delegates all of that to vgame and focuses purely on game logic.

## What vgame provides

- **App** -- window creation, lifecycle, fullscreen toggle, frame loop
- **Screen** -- design-space rendering with automatic letterboxing and scaling
- **RenderContext** -- vector drawing primitives (drawLines, drawNumber, drawCircle, etc.)
- **InputManager** -- unified keyboard + Xbox gamepad input with binding tables
- **AudioManager** -- load and play sound clips by index
- **Particles** -- line debris and dot explosion system with wrap-around
- **Math helpers** -- collision, wrapping, vector operations
- **Overlay** -- centered translucent panels for pause/help/game-over

## Features

- Ship movement, rotation, and thrust with drag
- Shooting with recoil
- Asteroid destruction and splitting (BIG -> MEDIUM -> SMALL)
- Alien saucers (BIG and SMALL) that shoot back at you
- Particle effects (line debris and dot explosions) via vgame.Particles
- Sound effects (shoot, thrust, asteroid hit, explosion, heartbeat bloop)
- Score tracking and bonus lives every 10,000 points
- Quantum rematerialization -- ship phases in with a color shift after respawn
- Shields with recharge timer
- Wrapping playfield (toroidal topology)
- Difficulty scales with score (more asteroids, faster bloop heartbeat)
- Gamepad support (Xbox controllers via GLFW mapping or raw joydev)

## Controls

| Key       | Action        |
|-----------|---------------|
| Left/Right| Rotate ship   |
| Up / W    | Thrust        |
| Down      | Shields       |
| Space     | Fire          |
| H / P     | Pause / Help  |
| 1         | New Game      |
| F         | Fullscreen    |

| Gamepad       | Action        |
|---------------|---------------|
| LS / D-PAD    | Rotate        |
| RT / X        | Thrust        |
| B / LT        | Shields       |
| A             | Shoot         |
| Start         | Pause/New Game|

## Requirements

- [Zig](https://ziglang.org/download/) 0.15.2
- raylib (built automatically via the vgame dependency chain)
- System development libraries for raylib's backend (GLFW, OpenGL, audio)

## Building

```bash
zig build
```

## Running

```bash
zig build run
# or
./zig-out/bin/zigsteroids2
# or fullscreen
./zig-out/bin/zigsteroids2 -f
```

## Project Structure

```
zigsteroids2/
  build.zig        # Build script -- depends on vgame as a local path dependency
  build.zig.zon    # Package manifest -- points to ../zigvectorgames
  src/
    main.zig       # All game logic (entities, update, render, overlays)
  resources/
    *.wav          # Sound effects (same as original zigsteroids)
```

## How it builds on vgame

The build.zig.zon declares vgame as a path dependency pointing to `../zigvectorgames`. The build.zig pulls in the vgame module and raylib artifact from that dependency. The game code imports `vgame` and uses its APIs directly -- no inline platform code, no custom input handler, no screen scaling logic. The original zigsteroids had ~2000 lines across two files; zigsteroids 2 is ~850 lines in a single file because vgame absorbs the platform layer.