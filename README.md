<div align="center">

```
   ____                             __  __            _
  / ___| _   _ _ __   ___ _ __    |  \/  | __ _ _ __(_) ___
  \___ \| | | | '_ \ / _ \ '__|   | |\/| |/ _` | '__| |/ _ \
   ___) | |_| | |_) |  __/ |      | |  | | (_| | |  | | (_) |
  |____/ \__,_| .__/ \___|_|      |_|  |_|\__,_|_|  |_|\___/
              |_|            E N G I N E
```

### 🍄 A side-scrolling platformer built from nothing but registers, a stack and a lot of patience 🍄

![Language](https://img.shields.io/badge/language-x86%20Assembly-b22222?style=for-the-badge)
![Assembler](https://img.shields.io/badge/assembler-NASM-1f6feb?style=for-the-badge)
![Platform](https://img.shields.io/badge/runs%20on-DOSBox%200.74-2ea043?style=for-the-badge)
![Video](https://img.shields.io/badge/video-VGA%20Mode%2013h-f2a900?style=for-the-badge)
![Size](https://img.shields.io/badge/game%20size-41%20KB-8a2be2?style=for-the-badge)

<br>

[![Watch the demo](https://img.shields.io/badge/%E2%96%B6%20%20WATCH%20THE%20GAMEPLAY%20DEMO-e60012?style=for-the-badge&logoColor=white)](https://drive.google.com/file/d/1jGhHl8G0h8q7L4kiUr4Fz5Lks8jRMT0D/view?usp=drive_link)

*EL2003 – Computer Organization and Assembly Language · FAST NUCES Chiniot-Faisalabad*

[The Idea](#-the-idea) · [Team](#-the-team) · [Quick Start](#-quick-start) · [Controls](#-controls) · [How to Play](#-how-to-play) · [Under the Hood](#%EF%B8%8F-under-the-hood) · [Files](#%EF%B8%8F-whats-inside)

</div>

---

## 🌟 The Idea

Jump pits. Squash walkers. Kick shells. Bonk question blocks. Touch the flag before the clock hits zero.

**Super Mario Engine** is a complete little platformer in **one 41 KB `.COM` file**. No C library, no graphics library, no engine. Every pixel, every sound and every frame is drawn by our own 16-bit code, and all the art and music are original.

<div align="center">

| 🧱 **192** tiles wide | 👾 **20** enemies | 🎵 **17 s** music loop | ❤️ **3** lives | ⏱️ **300** s clock |
|:-:|:-:|:-:|:-:|:-:|

</div>

## 🎬 Gameplay Demo

<div align="center">

### [▶ Click here to watch the game in action](https://drive.google.com/file/d/1jGhHl8G0h8q7L4kiUr4Fz5Lks8jRMT0D/view?usp=drive_link)

*Title screen → running and jumping → coins and mushrooms → stomps and shells → the flag pole*

</div>

## 👥 The Team

<div align="center">

| | Name | Roll No. |
|:-:|---|:-:|
| 🧢 | **Muhammad Ahsan Niaz** | 23F-0584 |
| 🧢 | **Muhammad Saad** | 25F-0662 |
| 🧢 | **Abdul Hanan** | 25F-0773 |

</div>

---

## 🚀 Quick Start

You need [NASM](https://nasm.us) on your PATH and [DOSBox 0.74](https://www.dosbox.com).

### ⚡ The easy way

Double-click **`PLAY.BAT`**. It builds the game and opens DOSBox with the right settings.

### 🔧 The manual way

```bat
nasm -f bin mario.asm -o MARIO.COM
```

Then inside DOSBox:

```
mount c "d:\Assembly Game"
c:
MARIO
```

> 💡 `MARIO.CONF` fixes the CPU speed (`cycles=fixed 30000`) so the game runs smoothly. Start DOSBox with `dosbox -conf MARIO.CONF`.
> A ready-built `MARIO.COM` is already in this repository.

---

## 🎮 Controls

<div align="center">

| Key | What it does |
|:-:|---|
| `←` `→` | 🏃 Walk |
| `Left Shift` | 💨 Run (hold) |
| `Space` | 🦘 Jump, hold longer to jump higher |
| `Enter` | ✅ Choose a menu item |
| `P` | ⏸️ Pause / resume |
| `Esc` | 🚪 Back to the title from the pause screen |
| `M` | 🔊 Sound on / off |

</div>

### 🛠️ Debug keys

| Key | Effect |
|:-:|---|
| `R` | Restart the level |
| `C` | Add 10 coins |
| `T` | Set the clock to 5 seconds |
| `1` `2` `3` | Teleport to three places in the level |

---

## 📖 How to Play

| You do this | You get this |
|---|---|
| 🟨 Hit a `?` block from below | Coin (**+200**) or a mushroom (**+1000**) |
| 🍄 Eat a mushroom | Small Mario becomes **Super Mario** |
| 🧱 Break a brick as Super Mario | **+50** |
| 👟 Stomp a walker | **+100**, then chains of 200, 400, 500, 800, 1000, 2000, 4000, 5000, 8000, and a **free life** |
| 🐢 Stomp a snail, then kick its shell | **+400**, and the shell kills what it hits (**+500** each) |
| 🪙 Collect 100 coins | **+1 life** |
| 🏁 Touch the flag pole | **5000** at the top down to **100** at the bottom, plus **time left × 50** |

> ⚠️ A hit as Super makes you Small, with 2 seconds of blinking protection. A hit as Small, a pit or the clock reaching 0 costs a life. You have **3 lives**.

---

## ⚙️ Under the Hood

| Piece | How we built it |
|---|---|
| 📦 **Program** | One 64 KB `.COM` segment (`ORG 100h`) |
| 🧮 **Procedures** | Parameters on the stack, `BP` frame, `ret N`, registers preserved |
| 🎨 **Video** | VGA mode 13h, own 17-colour palette, pixel at `y × 320 + x` |
| 🖼️ **Drawing** | Off-screen frame buffer, cleared with `REP STOSW`, shown with `REP MOVSW` |
| ⌨️ **Keyboard** | Our own `INT 09h` handler with a 128-byte key table and edge detection |
| ⏲️ **Timer** | Our own `INT 08h` handler at 30 Hz, chained to the BIOS, no delay loops |
| 🏃 **Physics** | 8.8 fixed-point speeds, gravity, variable-height jump |
| 🗺️ **World** | 192 × 12 tile map, 20 enemies in a record table |
| 🔢 **Score** | 32-bit with `ADD`/`ADC`, capped at 999,999 |
| 🎵 **Sound** | PC speaker through PIT channel 2, music plus effects from the timer interrupt |

### 🧊 Smooth, not flickery

Everything is drawn off-screen first, then shown once per frame during the vertical retrace. The HUD is cached, tiles are copied row by row, and when a computer runs late the game skips drawing (never logic) to keep the speed right.

### 💾 Memory choices

- Code, data and stack share one 64 KB segment, about 41 KB used.
- The 64,000-byte frame buffer lives in a **second DOS segment**. At start the program shrinks its own block (`INT 21h`, function 4Ah), then asks DOS for 4,000 paragraphs (function 48h). It is released on exit.
- The map has two copies (original and working), 192 × 12 bytes each. Enemies are 24 records of 16 bytes.

### 🔄 Game states

```
TITLE ──▶ PLAYING ◀──▶ PAUSED
              │
              ├──▶ DYING ──▶ LIFELOST ──▶ PLAYING
              │                  └─────▶ GAMEOVER ──▶ TITLE
              └──▶ WIN ──▶ LEVELDONE ──▶ TITLE

TITLE ──▶ EXIT   (clean return to DOS)
```

---

## 🗂️ What's Inside

| File | Purpose |
|---|---|
| 📜 `mario.asm` | The complete source code |
| 🎮 `MARIO.COM` | The built game |
| 🔨 `build.bat` | Build only |
| ▶️ `PLAY.BAT` | Build and run in one step |
| ⚙️ `MARIO.CONF` | DOSBox settings |

## ✨ Bonus Features

- 🌤️ A wide world with clouds, hills, bushes and a castle
- 🟥 Blinking red `?` blocks
- 🖥️ Tear-free, flicker-free drawing
- 🎵 Looping background music, sound effects and an `M` key to mute
- ⚡ One-command build and run with `PLAY.BAT`

## 🚧 Known Limitations

- Sound comes from the PC speaker, so it is one note at a time.
- The ending is simple: Mario slides down the pole, but the flag does not come down.
- There is only one level, World 1-1.
- Speed depends on the DOSBox `cycles` setting, so use `MARIO.CONF`.

---

<div align="center">

**Made with registers, one stack and zero libraries.** 🍄

⭐ *If you liked it, give the repo a star!* ⭐

</div>
