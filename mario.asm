; ==========================================================================
; MARIO.ASM  -  Super Mario Engine (EL2003 COAL Semester Project)
; 16-bit x86, NASM, DOS .COM program, VGA Mode 13h
; Build: nasm -f bin mario.asm -o MARIO.COM
;
; Stage 0-2 : Module 1 (skeleton) + Module 2 (video mode, colours,
;             PutPixel, FillRect)
; Stage 3-4 : Module 7 (own keyboard handler, INT 09h) +
;             Module 8 (own timer handler, INT 08h, game clock)
; Stage 5   : Module 3 (level map, tile drawing, GetTile, ResetMap)
; Stage 6   : Module 4 (sprites: DrawSprite with mirroring, clipping and a
;             half-transparent mode)
; Stage 7   : Module 5 (off-screen frame buffer in a second segment, block
;             clear and block copy)
; Stage 8   : Module 9 (player movement and physics, 8.8 fixed point)
; Stage 9   : Module 10 (tile collision) + Module 6 (camera)
; Stage 10  : Module 11 (enemies, shells, stomp chain, 32-bit score)
; Stage 11  : Module 12 (blocks, bricks, coins, mushroom power-up)
; Stage 12  : Module 13 (bitmap font, decimal output, hearts, level clock, HUD)
; Stage 13  : Module 14 (state machine, title, pause, dying, life lost, game over)
; Stage 14  : Module 15 (flag pole, win sequence, level complete screen, time bonus)
; Stage 15  : fixes after testing (Esc only in the pause, walkers keep out of pits,
;             no enemy respawn key, no Enter-to-grow key, life hearts in the HUD)
; Stage 16  : extended world (192 columns), clouds, hills, bushes, castle, 20 enemies
; Stage 18  : sound (PC speaker): background music, jump / coin / stomp / power-up sounds, victory and
;             death tunes, M = sound on/off
; Stage 17  : polish (crisp hill/bush outlines, blinking ? blocks, HUD: LIVES x3 and 3 hearts under
;             HEALTH, retrace sync against tearing, catch-up + cached HUD for slow DOSBox settings)
; ==========================================================================

BITS 16
ORG 100h                        ; .COM programs always start at offset 100h

; ==========================================================================
; CONSTANTS (Appendix A of the manual)
; ==========================================================================

; ---- Display and tiles (A.1) ----
SCREEN_W        equ 320
SCREEN_H        equ 200
VIDEO_SEG       equ 0A000h      ; VGA Mode 13h video memory
TILE_SIZE       equ 16
VIEW_COLS       equ 20          ; tiles visible across the screen
MAP_ROWS        equ 12
MAP_COLS        equ 192         ; level width in tiles (the extended world: about 10 screens)
LEVEL_PIXELS    equ 3072        ; MAP_COLS * TILE_SIZE
CAMERA_MAX      equ 2752        ; LEVEL_PIXELS - SCREEN_W
CAMERA_FOLLOW_X equ 160         ; Mario stays here once the screen scrolls
HUD_HEIGHT      equ 16          ; map row 0 is the HUD strip

; ---- Palette indexes (our own palette, see palette_table below) ----
COL_BLACK       equ 0           ; also the "transparent" index in sprites
COL_SKY         equ 1
COL_GRASS       equ 2
COL_DIRT        equ 3
COL_BRICK       equ 4
COL_PIPE        equ 5
COL_HERO_RED    equ 6
COL_SKIN        equ 7
COL_GOOMBA      equ 8
COL_WHITE       equ 9
COL_HUD_YELLOW  equ 10
COL_COIN        equ 11
COL_OUTLINE     equ 12
COL_STAIR       equ 13
COL_HERO_BLUE   equ 14
COL_KOOPA       equ 15
PAL_COUNT       equ 17          ; number of colours we program

; ---- Tile codes (A.2) ----
T_SKY           equ 0
T_GROUND        equ 1
T_BRICK         equ 2
T_QBLOCK_COIN   equ 3
T_QBLOCK_MUSH   equ 4
T_EMPTY         equ 5
T_PIPE_TL       equ 6
T_PIPE_TR       equ 7
T_PIPE_BL       equ 8
T_PIPE_BR       equ 9
T_STAIR         equ 10
T_COIN          equ 11
T_FLAG          equ 12
T_FLAG_TOP      equ 13          ; our own extra tile: flag pole top with flag
TILE_KINDS      equ 14          ; number of different tile bitmaps
MAP_SIZE        equ MAP_COLS * MAP_ROWS     ; 2304 bytes

; ---- Keyboard scan codes (A.3) ----
SC_ESC          equ 01h
SC_ENTER        equ 1Ch
SC_P            equ 19h
SC_R            equ 13h
SC_C            equ 2Eh
SC_T            equ 14h
SC_M            equ 32h          ; sound on/off
SYMBOL_COUNT    equ 14          ; characters in symbol_chars
DEATH_HOP       equ 0FB00h      ; -5.0 px/frame: the little jump of the death animation (about 48 px high)
DEATH_MIN       equ 30          ; the death animation lasts at least 1 s ...
DEATH_MAX       equ 90          ; ... and at most 3 s
FLAG_X          equ 2896        ; world x of the flag pole column (column 181)
BASE_Y          equ 144         ; top of the base block: where the slide ends
SLIDE_SPEED     equ 3           ; pixels per frame down the pole (about 1 s)
WIN_WALK_TICKS  equ 30          ; the walk after the slide: about 1 s
LIFELOST_TICKS  equ 60          ; Life-lost screen: about 2 s at 30 frames per second
SC_1            equ 02h
SC_2            equ 03h
SC_3            equ 04h
SC_LSHIFT       equ 2Ah
SC_SPACE        equ 39h
SC_UP           equ 48h
SC_LEFT         equ 4Bh
SC_RIGHT        equ 4Dh
SC_DOWN         equ 50h

; ---- Game limits (A.4) ----
START_LIVES     equ 3
MAX_LIVES       equ 99
LEVEL_TIME      equ 300
MAX_ENEMIES     equ 24          ; 20 enemies at the start + free slots for mushrooms
INVULN_TICKS    equ 60          ; about 2 s at 30 frames per second
MAX_SCORE_HI    equ 0Fh         ; 999,999 = 000F423Fh (high word 0Fh)
MAX_SCORE_LO    equ 423Fh

; ---- Game states (5.12) ----
ST_TITLE        equ 0
ST_PLAYING      equ 1
ST_PAUSED       equ 2
ST_DYING        equ 3
ST_LIFELOST     equ 4
ST_WIN          equ 5
ST_LEVELDONE    equ 6
ST_GAMEOVER     equ 7
ST_EXIT         equ 8

; ---- Physics, 8.8 fixed point (A.5) ----
WALK_ACCEL      equ 0020h
FRICTION        equ 0010h
MAX_WALK        equ 0180h
MAX_RUN         equ 0280h
GRAVITY         equ 0040h
BRAKE_ACCEL     equ 0040h       ; braking when steering against the movement
                                ; (faster than FRICTION, as Section 5.2 asks)
HIT_LEFT        equ 2           ; hitbox: 12 pixels wide, 2 pixels in from each side
HIT_RIGHT       equ 13
PIT_Y           equ 192         ; top of Mario at or below this = fell into a pit
ENEMY_SIZE      equ 16          ; bytes per enemy record (Section 5.5)
E_TYPE          equ 0           ;  type: 0 none, 1 walker, 2 snail
E_STATE         equ 1           ;  state: 0 waiting, 1 walking, 2 flat/shell, 3 sliding
E_X             equ 2           ;  world x (word, whole pixels)
E_XF            equ 4           ;  x fraction (byte)
E_DIR           equ 5           ;  0 = right, 1 = left
E_Y             equ 6           ;  world y of the FEET (word)
E_YF            equ 8           ;  y fraction (byte)
E_GND           equ 9           ;  1 = standing on the ground
E_VY            equ 10          ;  vertical speed 8.8 (word)
E_TIMER         equ 12          ;  flat-walker timer (word)
E_GRACE         equ 14          ;  frames a shell ignores Mario (byte)
ET_NONE         equ 0
ET_WALKER       equ 1
ET_SNAIL        equ 2
ES_WAIT         equ 0
ES_WALK         equ 1
ES_FLAT         equ 2           ; walker: flattened
ES_SHELL        equ 2           ; snail: stationary shell
ES_SLIDE        equ 3           ; snail: sliding shell
ET_MUSHROOM     equ 3           ; the power-up lives in the enemy table too
ES_EMERGE       equ 4           ; mushroom: rising out of its block
FX_SIZE         equ 8           ; bytes per effect record (coin popping out of a block)
MAX_FX          equ 4
FLAT_TICKS      equ 30          ; a flat walker stays 1 second
KICK_GRACE      equ 8           ; a shell ignores Mario for 8 frames after a kick
GROUND_Y        equ 160         ; y of the top of the ground (row 10 * 16)
HERO_START_X    equ 32          ; Mario's start position (Section 5.3)
JUMP_START      equ 0FA80h      ; -5.5 px/frame (two's complement)
JUMP_CUTOFF     equ 0FE00h      ; -2.0
MAX_FALL        equ 0400h       ; 4.0
STOMP_BOUNCE    equ 0FD00h      ; -3.0
; Walker behaviour flags for EnemyStep: bit 0 = turn at platform edges, bit 1 = turn
; at other enemies. 3 = the brown walker turns at pit edges like the snail (as
; requested after testing). The manual says a Goomba walks off ledges: use 2 for that.
WALKER_FLAGS    equ 3
GOOMBA_SPEED    equ 0080h
KOOPA_SPEED     equ 00C0h
SHELL_SPEED     equ 0300h
MUSHROOM_SPEED  equ 0100h

; ---- Frame buffer (Module 5) ----
FRAME_PARAS     equ 4000        ; 64,000 bytes = 4000 paragraphs of 16 bytes
COM_PARAS       equ 1000h       ; our own segment: 64 KB = 4096 paragraphs

; ---- DrawSprite flags (Module 4) ----
FLAG_MIRROR     equ 1           ; bit 0: draw the sprite facing left
FLAG_TALL       equ 2           ; bit 1: 16 x 32 sprite (Super hero)
FLAG_DITHER     equ 4           ; bit 2: half-transparent (every 2nd pixel)

; ---- Timer (Module 8) ----
; The PC timer chip counts at 1,193,182 Hz. It normally divides by 65536
; (18.2 ticks per second). We divide by 39773 instead, which gives
; 1193182 / 39773 = 30.0 ticks per second = 30 frames per second.
PIT_DIVISOR     equ 39773
TICKS_PER_SEC   equ 30

; ==========================================================================
; PROGRAM START
; ==========================================================================
start:
        cld                             ; string instructions count upward
        call    AllocFrameBuffer        ; second segment for the frame buffer
        jc      .no_memory              ; DOS said no

        call    SetVideoMode13h         ; enter 320x200, 256 colours
        call    SetPalette              ; load our own colours
        call    InstallKeyboard         ; take over INT 09h
        call    InstallTimer            ; take over INT 08h, speed up to 30 Hz
        call    ResetMap                ; working map = copy of the original map
        call    ResetHero               ; Mario at the start position
        call    ResetEnemies            ; enemies at their start positions
        call    ResetClock              ; 300 seconds on the level clock

        mov     byte [game_state], ST_TITLE     ; the program starts at the title screen
        mov     ax, [tick_count]        ; AX = the last tick we have seen
        mov     [last_tick], ax
.frame_loop:
        push    ax
        call    WaitNextTick            ; sleeps until the timer ticks; AX = new tick
        ; ---- catch-up: if drawing was slower than one tick (a slow DOSBox), the
        ; ---- game runs one step for every tick that passed (at most 6 in a row)
        ; ---- and draws only the last one, so the speed stays right.
        mov     bx, ax
        sub     bx, [last_tick]      ; BX = ticks since the last step
        mov     [last_tick], ax
        cmp     bx, 6
        jbe     .steps_ok
        mov     bx, 6
.steps_ok:
        cmp     bx, 1
        ja      .is_behind
        mov     byte [behind], 0
        jmp     short .step
.is_behind:
        mov     byte [behind], 1        ; no time to wait for the vertical retrace
.step:
        mov     [steps_left], bx
.step_loop:
        dec     word [steps_left]
        mov     al, 0
        cmp     word [steps_left], 0
        je      .draw_this
        mov     al, 1                   ; not the last step: do not draw it
.draw_this:
        mov     [skip_draw], al
        call    KeyEdges                ; which keys went down since the last frame
        call    HandleSoundKey          ; M = sound on / off
        call    RunState                ; the state machine: one step of the current state
        cmp     byte [game_state], ST_EXIT
        je      .leave
        cmp     word [steps_left], 0
        jne     .step_loop
        mov     ax, [last_tick]
        jmp     .frame_loop
.leave:

        ; ---- clean exit: undo everything we changed ----
        call    RemoveTimer
        call    RemoveKeyboard
        call    RestoreTextMode
        call    FreeFrameBuffer
        mov     ax, 4C00h               ; DOS: terminate, return code 0
        int     21h

.no_memory:                             ; (no hooks installed yet, nothing to undo)
        mov     dx, msg_no_memory
        mov     ah, 09h                 ; DOS: print the $-terminated text
        int     21h
        mov     ax, 4C01h               ; terminate, return code 1
        int     21h

; ==========================================================================
; MODULE 2 : VIDEO MODE, PALETTE AND DRAWING PRIMITIVES
; ==========================================================================

; --------------------------------------------------------------------------
; SetVideoMode13h
;   Purpose : switch the display to VGA Mode 13h (320x200, 256 colours)
;   Inputs  : none
;   Outputs : none
;   Changes : none (AX is saved and restored)
; --------------------------------------------------------------------------
SetVideoMode13h:
        push    ax
        mov     ax, 0013h               ; BIOS: AH=00 set mode, AL=13h
        int     10h
        pop     ax
        ret

; --------------------------------------------------------------------------
; RestoreTextMode
;   Purpose : go back to 80x25 text mode (called on every exit path)
;   Inputs  : none
;   Outputs : none
;   Changes : none
; --------------------------------------------------------------------------
RestoreTextMode:
        push    ax
        mov     ax, 0003h               ; BIOS: set mode 3 (text)
        int     10h
        pop     ax
        ret

; --------------------------------------------------------------------------
; SetPalette
;   Purpose : program VGA colours 0..PAL_COUNT-1 from palette_table.
;             Each colour is 3 bytes (red, green, blue), 0..63 each.
;   Inputs  : none (reads palette_table, DS = CS in a .COM file)
;   Outputs : none
;   Changes : none
; --------------------------------------------------------------------------
SetPalette:
        push    ax
        push    cx
        push    dx
        push    si
        pushf                           ; keep the direction flag as it was
        cld

        mov     dx, 3C8h                ; DAC write-index port
        xor     al, al                  ; start at colour 0
        out     dx, al
        inc     dx                      ; 3C9h = DAC data port
        mov     si, palette_table
        mov     cx, PAL_COUNT * 3       ; three bytes per colour
.next_byte:
        lodsb                           ; AL = next palette byte
        out     dx, al
        loop    .next_byte

        popf
        pop     si
        pop     dx
        pop     cx
        pop     ax
        ret

; --------------------------------------------------------------------------
; PutPixel(x, y, colour)
;   Purpose : draw one pixel. Pixels outside the screen are ignored.
;   Inputs  : on the stack, pushed in this order: x, y, colour
;             ES = destination segment (video memory or frame buffer)
;   Outputs : none
;   Changes : none (the routine removes its own 6 bytes of parameters)
;   Offset  : y*320 + x  =  (y << 8) + (y << 6) + x
; --------------------------------------------------------------------------
PutPixel:
        push    bp
        mov     bp, sp
        push    ax
        push    bx
        push    di
        ; [bp+4] = colour, [bp+6] = y, [bp+8] = x

        mov     ax, [bp+8]              ; AX = x
        cmp     ax, SCREEN_W            ; unsigned compare also rejects x < 0
        jae     .done
        mov     bx, [bp+6]              ; BX = y
        cmp     bx, SCREEN_H
        jae     .done

        mov     di, bx
        shl     di, 8                   ; y * 256
        shl     bx, 6                   ; y * 64
        add     di, bx                  ; y * 320
        add     di, ax                  ; + x
        mov     al, [bp+4]
        mov     [es:di], al
.done:
        pop     di
        pop     bx
        pop     ax
        pop     bp
        ret     6

; --------------------------------------------------------------------------
; FillRect(x, y, w, h, colour)
;   Purpose : fill a rectangle. The part outside the screen is clipped
;             away, so x and y may be negative or too large.
;   Inputs  : on the stack, pushed in this order: x, y, w, h, colour
;             ES = destination segment
;   Outputs : none
;   Changes : none (the routine removes its own 10 bytes of parameters)
; --------------------------------------------------------------------------
FillRect:
        push    bp
        mov     bp, sp
        push    ax
        push    bx
        push    cx
        push    dx
        push    si
        push    di
        pushf
        ; [bp+4]=colour [bp+6]=h [bp+8]=w [bp+10]=y [bp+12]=x

        mov     bx, [bp+12]             ; BX = left edge
        mov     dx, [bp+10]             ; DX = top edge
        mov     si, [bp+12]
        add     si, [bp+8]              ; SI = right edge  (x + w)
        mov     cx, [bp+10]
        add     cx, [bp+6]              ; CX = bottom edge (y + h)

        ; clip against the four screen edges (signed compares)
        cmp     bx, 0
        jge     .left_ok
        xor     bx, bx
.left_ok:
        cmp     dx, 0
        jge     .top_ok
        xor     dx, dx
.top_ok:
        cmp     si, SCREEN_W
        jle     .right_ok
        mov     si, SCREEN_W
.right_ok:
        cmp     cx, SCREEN_H
        jle     .bottom_ok
        mov     cx, SCREEN_H
.bottom_ok:
        cmp     bx, si                  ; nothing left to draw?
        jge     .done
        cmp     dx, cx
        jge     .done

        sub     si, bx                  ; SI = visible width
        sub     cx, dx                  ; CX = visible height = row counter

        mov     di, dx                  ; DI = top * 320 + left
        shl     di, 8
        shl     dx, 6
        add     di, dx
        add     di, bx

        mov     al, [bp+4]              ; AL = colour
        cld
.row:
        push    cx                      ; save the row counter
        push    di                      ; save the start of this row
        mov     cx, si                  ; CX = pixels in this row
        rep stosb                       ; fill one row
        pop     di
        add     di, SCREEN_W            ; move down one row
        pop     cx
        loop    .row
.done:
        popf
        pop     di
        pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        pop     bp
        ret     10

; ==========================================================================
; MODULE 7 : KEYBOARD INTERRUPT HANDLER (INT 09h)
; ==========================================================================

; --------------------------------------------------------------------------
; InstallKeyboard
;   Purpose : remember the DOS/BIOS keyboard handler (INT 21h AH=35h) and
;             replace it with KeyboardISR (INT 21h AH=25h).
;   Inputs  : none (DS = CS)
;   Outputs : none (old vector saved in old_int09_off / old_int09_seg)
;   Changes : none
; --------------------------------------------------------------------------
InstallKeyboard:
        push    ax
        push    bx
        push    dx
        push    es                      ; AH=35h returns its answer in ES:BX

        mov     ax, 3509h               ; get vector of INT 09h
        int     21h
        mov     [old_int09_off], bx
        mov     [old_int09_seg], es

        mov     dx, KeyboardISR         ; DS:DX = our handler
        mov     ax, 2509h               ; set vector of INT 09h
        int     21h

        pop     es
        pop     dx
        pop     bx
        pop     ax
        ret

; --------------------------------------------------------------------------
; RemoveKeyboard
;   Purpose : put the original keyboard handler back. Must run on every
;             exit path, otherwise DOS no longer sees the keyboard.
;   Inputs  : none
;   Outputs : none
;   Changes : none
; --------------------------------------------------------------------------
RemoveKeyboard:
        push    ax
        push    dx
        push    ds

        mov     dx, [old_int09_off]     ; read both parts while DS is still ours
        mov     ax, [old_int09_seg]
        mov     ds, ax                  ; DS:DX = original handler
        mov     ax, 2509h
        int     21h

        pop     ds
        pop     dx
        pop     ax
        ret

; --------------------------------------------------------------------------
; KeyboardISR   (runs by itself every time a key goes down or up)
;   Purpose : read the scan code from port 60h and keep key_state[] up to
;             date: 1 = key held, 0 = key released.
;   Notes   : bit 7 of the scan code is set for a key RELEASE.
;             Arrow keys send an extra E0h byte first; we ignore that byte
;             and handle the code that follows.
;             We do NOT chain to the old handler, so the BIOS keyboard
;             buffer stays empty; the game reads key_state[] only.
;   Changes : none (everything is saved, ends with IRET)
; --------------------------------------------------------------------------
KeyboardISR:
        push    ax
        push    bx
        push    ds
        push    cs
        pop     ds                      ; DS = CS so we can reach our variables

        in      al, 60h                 ; AL = scan code from the keyboard
        cmp     al, 0E0h                ; extended-key prefix? ignore it
        je      .acknowledge

        mov     bl, al
        and     bl, 7Fh                 ; BL = key number without the release bit
        xor     bh, bh                  ; BX = index into key_state
        test    al, 80h                 ; bit 7 set = release
        jnz     .released
        mov     byte [key_state + bx], 1
        jmp     short .acknowledge
.released:
        mov     byte [key_state + bx], 0

.acknowledge:
        mov     al, 20h                 ; end-of-interrupt to the interrupt
        out     20h, al                 ; controller, or no more keys arrive

        pop     ds
        pop     bx
        pop     ax
        iret

; ==========================================================================
; MODULE 8 : TIMER INTERRUPT HANDLER AND GAME CLOCK (INT 08h)
; ==========================================================================

; --------------------------------------------------------------------------
; InstallTimer
;   Purpose : save the BIOS timer handler, install TimerISR, then speed the
;             timer chip up from 18.2 Hz to 30 Hz (PIT_DIVISOR).
;   Inputs  : none
;   Outputs : none (old vector saved in old_int08_off / old_int08_seg)
;   Changes : none
; --------------------------------------------------------------------------
InstallTimer:
        push    ax
        push    bx
        push    dx
        push    es

        mov     ax, 3508h               ; get vector of INT 08h
        int     21h
        mov     [old_int08_off], bx
        mov     [old_int08_seg], es

        mov     dx, TimerISR
        mov     ax, 2508h               ; set vector of INT 08h
        int     21h

        cli                             ; program the timer chip
        mov     al, 36h                 ; channel 0, low+high byte, square wave
        out     43h, al
        mov     ax, PIT_DIVISOR
        out     40h, al                 ; low byte of divisor
        mov     al, ah
        out     40h, al                 ; high byte of divisor
        sti

        pop     es
        pop     dx
        pop     bx
        pop     ax
        ret

; --------------------------------------------------------------------------
; RemoveTimer
;   Purpose : restore the BIOS timer handler and the normal 18.2 Hz rate
;             (a divisor of 0 means 65536). Must run on every exit path.
;   Inputs  : none
;   Outputs : none
;   Changes : none
; --------------------------------------------------------------------------
RemoveTimer:
        push    ax
        push    dx
        push    ds

        mov     dx, [old_int08_off]
        mov     ax, [old_int08_seg]
        mov     ds, ax                  ; DS:DX = original handler
        mov     ax, 2508h
        int     21h
        pop     ds                      ; DS is ours again

        cli                             ; normal rate back on the timer chip
        mov     al, 36h
        out     43h, al
        xor     al, al                  ; divisor 0 = 65536 = the default rate
        out     40h, al
        out     40h, al
        sti

        in      al, 61h                 ; and the speaker off (we used timer channel 2)
        and     al, 0FCh
        out     61h, al

        pop     dx
        pop     ax
        ret

; --------------------------------------------------------------------------
; TimerISR   (runs 30 times per second)
;   Purpose : count ticks and whole seconds for the game.
;   Notes   : The BIOS and DOS clock expects 18.2 ticks per second. We now
;             tick faster, so we pass only some ticks on to the BIOS:
;             bios_acc adds PIT_DIVISOR each tick; whenever it wraps past
;             65536 (carry flag set) one real BIOS tick is due and we jump
;             to the original handler, which also sends the end-of-interrupt.
;             On the other ticks we send the end-of-interrupt ourselves.
;   Changes : none (everything is saved)
; --------------------------------------------------------------------------
TimerISR:
        push    ax
        push    ds
        push    cs
        pop     ds                      ; DS = CS

        inc     word [tick_count]       ; one more frame tick

        inc     byte [tick_in_second]   ; count 30 ticks = 1 second
        cmp     byte [tick_in_second], TICKS_PER_SEC
        jb      .same_second
        mov     byte [tick_in_second], 0
        inc     word [seconds_count]    ; one more real second
.same_second:
        call    SoundTick               ; music and sound effects (a few instructions)

        add     word [bios_acc], PIT_DIVISOR
        jc      .chain_to_bios          ; wrapped: a BIOS tick is due

        mov     al, 20h                 ; no BIOS tick: acknowledge ourselves
        out     20h, al
        pop     ds
        pop     ax
        iret

.chain_to_bios:
        pop     ds
        pop     ax
        jmp     far [cs:old_int08_off]  ; hand over to the original handler,
                                        ; it finishes with IRET for us

; --------------------------------------------------------------------------
; WaitNextTick(last_tick)
;   Purpose : sleep until the timer interrupt has ticked again. This is
;             what keeps the game at the same speed on every computer.
;   Inputs  : on the stack: last_tick (the tick count we saw last time)
;   Outputs : AX = the new tick count
;   Changes : AX only (HLT just pauses the CPU until the next interrupt)
; --------------------------------------------------------------------------
WaitNextTick:
        push    bp
        mov     bp, sp
.wait:
        hlt                             ; pause until any interrupt arrives
        mov     ax, [tick_count]
        cmp     ax, [bp+4]              ; same as last time? keep waiting
        je      .wait
        pop     bp
        ret     2

; ==========================================================================
; MODULE 3 : LEVEL MAP AND TILE DRAWING
; ==========================================================================

; --------------------------------------------------------------------------
; GetTile(px, py)
;   Purpose : find the tile code at a pixel position of the WORKING map.
;             All collision and block logic will use this one routine.
;   Inputs  : on the stack, pushed in this order: px, py (world pixels)
;   Outputs : AX = tile code (0..62; 14 and up are scenery)
;             left or right of the level -> T_GROUND (an invisible wall)
;             above or below the map     -> T_SKY (empty air, pit)
;   Changes : AX only
;   Index   : column = px / 16, row = py / 16, index = row * 192 + column
;             row * 192 is worked out as (row << 7) + (row << 6)
; --------------------------------------------------------------------------
GetTile:
        push    bp
        mov     bp, sp
        push    bx
        push    cx
        ; [bp+4] = py, [bp+6] = px

        mov     bx, [bp+6]              ; BX = px
        mov     ax, [bp+4]              ; AX = py
        cmp     bx, LEVEL_PIXELS        ; unsigned: also catches px < 0
        jae     .side_wall
        cmp     ax, MAP_ROWS * TILE_SIZE
        jae     .open_air               ; unsigned: above (<0) or below the map

        shr     bx, 4                   ; BX = column
        shr     ax, 4                   ; AX = row
        mov     cx, ax
        shl     ax, 7                   ; row * 128
        shl     cx, 6                   ; row * 64
        add     ax, cx                  ; row * 192
        add     bx, ax                  ; BX = index into the map
        mov     al, [level_working + bx]   ; based-indexed read
        xor     ah, ah
        jmp     short .done
.side_wall:
        mov     ax, T_GROUND
        jmp     short .done
.open_air:
        xor     ax, ax                  ; T_SKY
.done:
        pop     cx
        pop     bx
        pop     bp
        ret     4

; --------------------------------------------------------------------------
; SetTile(px, py, tile)
;   Purpose : change one tile of the WORKING map (used later when a block is
;             hit or a coin is collected). Positions outside the map are
;             ignored. The original map is never touched.
;   Inputs  : on the stack, pushed in this order: px, py, tile
;   Outputs : none
;   Changes : none
; --------------------------------------------------------------------------
SetTile:
        push    bp
        mov     bp, sp
        push    ax
        push    bx
        push    cx
        ; [bp+4] = tile, [bp+6] = py, [bp+8] = px

        mov     bx, [bp+8]              ; BX = px
        mov     ax, [bp+6]              ; AX = py
        cmp     bx, LEVEL_PIXELS
        jae     .done
        cmp     ax, MAP_ROWS * TILE_SIZE
        jae     .done

        shr     bx, 4                   ; column
        shr     ax, 4                   ; row
        mov     cx, ax
        shl     ax, 7
        shl     cx, 6
        add     ax, cx                  ; row * 192
        add     bx, ax
        mov     al, [bp+4]
        mov     [level_working + bx], al
.done:
        pop     cx
        pop     bx
        pop     ax
        pop     bp
        ret     6

; --------------------------------------------------------------------------
; ResetMap
;   Purpose : copy the original map over the working map with one block-move
;             instruction. Called at the start of every new life / new game.
;   Inputs  : none
;   Outputs : none
;   Changes : none
; --------------------------------------------------------------------------
ResetMap:
        push    cx
        push    si
        push    di
        push    es
        pushf

        push    ds
        pop     es                      ; ES = DS, both are our own segment
        cld
        mov     si, level_original
        mov     di, level_working
        mov     cx, MAP_SIZE / 2        ; 1152 words
        rep movsw                       ; block move

        popf
        pop     es
        pop     di
        pop     si
        pop     cx
        ret

; --------------------------------------------------------------------------
; DrawTile(x, y, tile)
;   Purpose : draw one 16 x 16 tile at a screen position. The picture is
;             clipped at every screen edge, so x may be -15..319 while the
;             screen scrolls.
;   Inputs  : on the stack, pushed in this order: x, y, tile
;             ES = destination segment
;   Outputs : none
;   Changes : none
;   Method  : the tile bitmap is at tile_gfx + tile * 256. Each of the 16 rows
;             is copied with REP MOVSW (REP MOVSB when clipped); the clipping only changes where a row
;             starts and how many bytes are copied.
; --------------------------------------------------------------------------
DrawTile:
        push    bp
        mov     bp, sp
        push    ax
        push    bx
        push    cx
        push    dx
        push    si
        push    di
        pushf
        ; [bp+4] = tile, [bp+6] = y, [bp+8] = x

        cld
        mov     bx, [bp+8]              ; BX = x (signed)
        mov     dx, [bp+6]              ; DX = y of the first row
        mov     si, [bp+4]
        shl     si, 8                   ; tile * 256
        add     si, tile_gfx            ; SI = first byte of the bitmap
        mov     cx, 16                  ; CX = visible width

        cmp     bx, 0                   ; cut off on the left?
        jge     .left_ok
        mov     ax, bx
        neg     ax                      ; AX = pixels outside the screen
        add     si, ax                  ; skip them in every source row
        add     cx, bx                  ; width = 16 + x (x is negative)
        xor     bx, bx                  ; start at screen column 0
.left_ok:
        mov     ax, bx
        add     ax, cx                  ; AX = right edge
        cmp     ax, SCREEN_W
        jle     .right_ok
        mov     cx, SCREEN_W            ; cut off on the right
        sub     cx, bx
.right_ok:
        cmp     cx, 0
        jle     .done                   ; nothing visible

        mov     ax, 16                  ; AX = rows left to copy
.row_loop:
        cmp     dx, SCREEN_H            ; unsigned: skips rows above and below
        jae     .next_row
        mov     di, dx
        shl     di, 8                   ; y * 256
        push    dx
        shl     dx, 6                   ; y * 64
        add     di, dx
        pop     dx
        add     di, bx                  ; + x
        push    cx
        push    si
        cmp     cx, 16
        jne     .copy_bytes
        mov     cx, 8                   ; whole tile row: 8 words are twice as fast
        rep movsw
        jmp     short .row_copied
.copy_bytes:
        rep movsb                       ; copy the visible part of this row
.row_copied:
        pop     si
        pop     cx
.next_row:
        add     si, 16                  ; next row of the bitmap
        inc     dx                      ; next screen row
        dec     ax
        jnz     .row_loop
.done:
        popf
        pop     di
        pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        pop     bp
        ret     6

; --------------------------------------------------------------------------
; DrawMap(camera_x)
;   Purpose : draw the part of the working map that is on the screen.
;             The first column is camera_x / 16 and it starts camera_x mod 16
;             pixels to the left of the screen edge, so the picture scrolls
;             one pixel at a time. 21 columns (20 + one partial) x 12 rows.
;             Sky tiles are NOT drawn (this saves most of the work): the
;             caller must first clear the destination to sky blue.
;   Inputs  : on the stack: camera_x (0..2752)
;             ES = destination segment, already cleared to COL_SKY
;   Outputs : none
;   Changes : none
; --------------------------------------------------------------------------
DrawMap:
        push    bp
        mov     bp, sp
        push    ax
        push    bx
        push    cx
        push    dx
        push    si
        push    di
        sub     sp, 6                   ; three local words:
                                        ; [bp-14] first column
                                        ; [bp-16] screen x of the first column
                                        ; [bp-18] current row
        ; [bp+4] = camera_x

        mov     ax, [bp+4]
        mov     bx, ax
        shr     bx, 4                   ; first column = camera_x / 16
        mov     [bp-14], bx
        and     ax, 15                  ; camera_x mod 16
        neg     ax                      ; 0 .. -15
        mov     [bp-16], ax
        mov     word [bp-18], 0         ; row 0

        ; which picture do the ? blocks show? it changes every 12 ticks (about 0.4 s)
        mov     ax, [tick_count]
        xor     dx, dx
        mov     bx, 10
        div     bx                      ; AX = tick_count / 12
        mov     byte [q_picture], T_QBLOCK_COIN
        test    al, 1
        jz      .row_loop
        mov     byte [q_picture], Q_ORANGE      ; every second period: the red picture

.row_loop:
        mov     ax, [bp-18]             ; row * 192 + first column = map index
        mov     bx, ax
        shl     bx, 7
        shl     ax, 6
        add     bx, ax
        add     bx, [bp-14]
        lea     si, [level_working + bx]   ; SI -> first visible tile of this row
        mov     bx, [bp-14]             ; BX = map column being drawn
        mov     di, [bp-16]             ; DI = its screen x
        mov     cx, VIEW_COLS + 1       ; 21 columns

.col_loop:
        cmp     bx, MAP_COLS            ; past the right end of the level?
        jae     .row_done
        cmp     byte [si], T_SKY        ; sky? the buffer is already sky
        je      .next_column
        push    di                      ; x
        mov     ax, [bp-18]
        shl     ax, 4
        push    ax                      ; y = row * 16
        mov     al, [si]
        cmp     al, T_QBLOCK_COIN       ; both kinds of ? block share one blinking picture
        jb      .tile_chosen
        cmp     al, T_QBLOCK_MUSH
        ja      .tile_chosen
        mov     al, [q_picture]
.tile_chosen:
        xor     ah, ah
        push    ax                      ; tile code
        call    DrawTile
.next_column:
        inc     si
        inc     bx
        add     di, TILE_SIZE
        loop    .col_loop

.row_done:
        inc     word [bp-18]
        cmp     word [bp-18], MAP_ROWS
        jb      .row_loop

        add     sp, 6                   ; drop the local words
        pop     di
        pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        pop     bp
        ret     2

; ==========================================================================
; MODULE 4 : SPRITES
; ==========================================================================

; --------------------------------------------------------------------------
; DrawSprite(x, y, address, flags)
;   Purpose : draw a sprite bitmap at a screen position.
;             Colour index 0 is transparent and is never drawn.
;             Every pixel is checked against the screen edges, so a sprite
;             may hang over any side of the screen without writing outside
;             video memory.
;   Inputs  : on the stack, pushed in this order: x, y, address, flags
;             x, y    = screen position of the top-left corner (signed)
;             address = first byte of the bitmap (16 bytes per row)
;             flags   = FLAG_MIRROR  face left (each row is read backwards)
;                       FLAG_TALL    32 rows instead of 16
;                       FLAG_DITHER  draw only every second pixel (a
;                                    checkerboard) = half-transparent
;             ES = destination segment
;   Outputs : none
;   Changes : none (the routine removes its own 8 bytes of parameters)
;   Mirror  : LODSB reads the source row backwards when the direction flag
;             is set (STD), so no second copy of the bitmap is needed.
; --------------------------------------------------------------------------
DrawSprite:
        push    bp
        mov     bp, sp
        push    ax
        push    bx
        push    cx
        push    dx
        push    si
        push    di
        pushf                           ; the direction flag is restored at the end
        ; [bp+4]=flags [bp+6]=address [bp+8]=y [bp+10]=x

        cld
        test    word [bp+4], FLAG_MIRROR
        jz      .direction_set
        std                             ; mirrored: LODSB steps backwards
.direction_set:
        mov     si, [bp+6]              ; SI = bitmap
        mov     dx, [bp+8]              ; DX = screen y of the current row
        mov     cx, 16                  ; CX = rows left
        test    word [bp+4], FLAG_TALL
        jz      .rows_set
        mov     cx, 32
.rows_set:

.row_loop:
        cmp     dx, SCREEN_H            ; unsigned: rows above and below are skipped
        jae     .skip_row
        mov     di, dx
        shl     di, 8                   ; y * 256
        push    dx
        shl     dx, 6                   ; y * 64
        add     di, dx
        pop     dx                      ; DI = y * 320
        push    cx                      ; save the rows-left counter
        mov     cx, 16                  ; CX = pixels left in this row
        mov     bx, [bp+10]             ; BX = screen x of the leftmost pixel
        test    word [bp+4], FLAG_MIRROR
        jz      .pixel_loop
        add     si, 15                  ; mirrored: start at the right end of the row
.pixel_loop:
        lodsb                           ; AL = next pixel of the bitmap
        or      al, al
        jz      .next_pixel             ; colour 0 = transparent
        cmp     bx, SCREEN_W
        jae     .next_pixel             ; outside the left or right edge
        test    word [bp+4], FLAG_DITHER
        jz      .put_pixel
        mov     ah, bl                  ; half-transparent: keep pixels where
        add     ah, dl                  ; (x + y) is even, skip the others
        test    ah, 1
        jnz     .next_pixel
.put_pixel:
        mov     [es:di+bx], al          ; base + index addressing
.next_pixel:
        inc     bx
        loop    .pixel_loop
        pop     cx
        test    word [bp+4], FLAG_MIRROR
        jz      .next_row
        add     si, 17                  ; was at row start - 1, move to next row
        jmp     short .next_row
.skip_row:
        add     si, 16                  ; skipped row: just step over it
.next_row:
        inc     dx
        loop    .row_loop

        popf
        pop     di
        pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        pop     bp
        ret     8

; ==========================================================================
; MODULE 5 : FRAME BUFFER AND BLOCK OPERATIONS
; ==========================================================================
; MEMORY PLAN (also written in the README):
;   A .COM program owns one 64 KB segment for code, data and stack. A
;   64,000-byte frame buffer does not fit beside them, so at start-up we
;     1. give back to DOS everything above our own 64 KB    (INT 21h AH=4Ah)
;     2. ask DOS for a new block of 4000 paragraphs (64,000 bytes)
;                                                           (INT 21h AH=48h)
;   DOS answers with the segment number of the new block; we keep it in
;   frame_seg. All drawing goes into that segment. Once per timer tick one
;   REP MOVSW copies it to video memory (segment A000h), so the player never
;   sees a half-drawn picture.
; ==========================================================================

; --------------------------------------------------------------------------
; AllocFrameBuffer
;   Purpose : reserve the second segment for the frame buffer.
;   Inputs  : none
;   Outputs : carry clear = success, frame_seg holds the segment number
;             carry set   = DOS could not give us the memory
;   Changes : AX (undefined), flags
; --------------------------------------------------------------------------
AllocFrameBuffer:
        push    bx
        push    es

        mov     ax, cs
        mov     es, ax                  ; ES = our own segment (the PSP)
        mov     bx, COM_PARAS           ; keep 64 KB, release the rest
        mov     ah, 4Ah
        int     21h
        jc      .failed

        mov     bx, FRAME_PARAS         ; ask for 4000 paragraphs
        mov     ah, 48h
        int     21h                     ; AX = segment of the new block
        jc      .failed
        mov     [frame_seg], ax
        clc
        jmp     short .leave
.failed:
        stc
.leave:
        pop     es                      ; POP does not change the carry flag
        pop     bx
        ret

; --------------------------------------------------------------------------
; FreeFrameBuffer
;   Purpose : give the frame buffer back to DOS (called on a normal exit).
;   Inputs  : none (reads frame_seg)
;   Outputs : none
;   Changes : none
; --------------------------------------------------------------------------
FreeFrameBuffer:
        push    ax
        push    es
        mov     ax, [frame_seg]
        mov     es, ax                  ; ES = block to free
        mov     ah, 49h
        int     21h
        pop     es
        pop     ax
        ret

; --------------------------------------------------------------------------
; ClearBuffer(colour)
;   Purpose : fill the whole 64,000 bytes of a buffer with one colour using
;             one block-store instruction (not a pixel loop).
;   Inputs  : on the stack: colour (0..255)
;             ES = the buffer to clear
;   Outputs : none
;   Changes : none
; --------------------------------------------------------------------------
ClearBuffer:
        push    bp
        mov     bp, sp
        push    ax
        push    cx
        push    di
        pushf

        mov     al, [bp+4]              ; AL = colour
        mov     ah, al                  ; AX = two pixels of that colour
        xor     di, di                  ; start at offset 0
        mov     cx, SCREEN_W * SCREEN_H / 2     ; 32,000 words
        cld
        rep stosw                       ; store AX 32,000 times

        popf
        pop     di
        pop     cx
        pop     ax
        pop     bp
        ret     2

; --------------------------------------------------------------------------
; PresentFrame(source_segment)
;   Purpose : copy a finished frame to the screen with one block move.
;   Inputs  : on the stack: source_segment (the frame buffer segment)
;   Outputs : none
;   Changes : none (DS and ES are saved and restored)
; --------------------------------------------------------------------------
PresentFrame:
        push    bp
        mov     bp, sp
        push    ax
        push    cx
        push    si
        push    di
        push    ds
        push    es
        pushf

        mov     ax, [bp+4]
        mov     ds, ax                  ; DS:SI = start of the frame buffer
        xor     si, si
        mov     ax, VIDEO_SEG
        mov     es, ax                  ; ES:DI = start of video memory
        xor     di, di
        mov     cx, SCREEN_W * SCREEN_H / 2     ; 32,000 words
        cld
        rep movsw                       ; the one and only write to the screen

        popf
        pop     es
        pop     ds
        pop     di
        pop     si
        pop     cx
        pop     ax
        pop     bp
        ret     2

; ==========================================================================
; MODULE 9 : PLAYER MOVEMENT AND PHYSICS
; ==========================================================================
; NUMBER FORMAT (also written in the README):
;   Speeds are 8.8 fixed point in one signed word: the high byte is whole
;   pixels per frame, the low byte is the fraction (0020h = 0.125 px/frame,
;   FA80h = -5.5 px/frame in two's complement).
;   An 8.8 word cannot hold a position up to 960, so a position is the whole
;   pixels in one word plus an 8-bit fraction in a byte (hero_x + hero_xf).
;   Adding a speed to a position adds the fraction bytes first; the carry
;   moves into the whole-pixel word (ADD, then ADC).
;   hero_x is the left edge of the sprite, hero_y is the y of the FEET, so
;   the feet stay fixed when Mario changes between Small and Super.
; ==========================================================================

; --------------------------------------------------------------------------
; MoveToward(current, target, step)
;   Purpose : change a signed value towards a target by at most `step`,
;             never going past the target. Used for acceleration, braking
;             and friction.
;   Inputs  : on the stack, pushed in this order: current, target, step
;             (current and target signed, step positive)
;   Outputs : AX = the new value
;   Changes : AX only
; --------------------------------------------------------------------------
MoveToward:
        push    bp
        mov     bp, sp
        push    bx
        ; [bp+4] = step, [bp+6] = target, [bp+8] = current

        mov     ax, [bp+8]              ; AX = current
        mov     bx, [bp+6]              ; BX = target
        cmp     ax, bx
        je      .done                   ; already there
        jl      .below                  ; current < target (signed)

        sub     ax, [bp+4]              ; current > target: go down by step
        cmp     ax, bx
        jge     .done
        mov     ax, bx                  ; but not past the target
        jmp     short .done
.below:
        add     ax, [bp+4]              ; go up by step
        cmp     ax, bx
        jle     .done
        mov     ax, bx                  ; but not past the target
.done:
        pop     bx
        pop     bp
        ret     6

; --------------------------------------------------------------------------
; ResetHero
;   Purpose : put Mario back to the start: Small, health 1, standing at the
;             level start, no speed. Used for every new life and new game.
;   Inputs  : none
;   Outputs : none
;   Changes : none
; --------------------------------------------------------------------------
ResetHero:
        mov     word [hero_x], HERO_START_X
        mov     byte [hero_xf], 0
        mov     word [hero_y], GROUND_Y         ; feet on the ground
        mov     byte [hero_yf], 0
        mov     word [hero_vx], 0
        mov     word [hero_vy], 0
        mov     byte [hero_form], 0             ; Small
        mov     byte [hero_hp], 1
        mov     byte [hero_on_ground], 1
        mov     byte [hero_facing], 0           ; facing right
        mov     byte [hero_jump_latch], 0
        mov     word [hero_invuln], 0
        mov     word [stomp_chain], 0
        ret

; --------------------------------------------------------------------------
; UpdateHero
;   Purpose : one frame of Mario's movement (Section 5.2), in this order:
;             1 steering  2 horizontal speed  3 jump  4 gravity
;             5 move sideways  6 move up/down + floor.
;   Inputs  : none (reads key_state: Left, Right, Left Shift, Space)
;   Outputs : updates the hero variables
;   Changes : none
; --------------------------------------------------------------------------
UpdateHero:
        push    ax
        push    bx
        push    cx
        push    dx
        mov     byte [bump_flag], 0     ; set again below if his head hits a tile
        mov     ax, [hero_y]
        mov     [hero_prev_y], ax       ; feet of the previous frame (stomp test)
        cmp     word [hero_invuln], 0
        je      .no_invuln
        dec     word [hero_invuln]      ; invulnerability runs out
.no_invuln:

        ; ---- 1. steering: CX = +1 (right), -1 (left), 0 (none or both) ----
        xor     cx, cx
        cmp     byte [key_state + SC_RIGHT], 0
        je      .right_up
        inc     cx
.right_up:
        cmp     byte [key_state + SC_LEFT], 0
        je      .left_up
        dec     cx
.left_up:

        ; ---- 2. horizontal speed ----
        mov     ax, [hero_vx]
        or      cx, cx
        jnz     .steering

        push    ax                      ; no key: friction pulls the speed to 0
        push    word 0
        push    word FRICTION
        call    MoveToward
        jmp     .speed_done

.steering:
        mov     dx, MAX_WALK            ; speed limit: walk, or run with Shift
        cmp     byte [key_state + SC_LSHIFT], 0
        je      .limit_known
        mov     dx, MAX_RUN
.limit_known:
        mov     byte [hero_facing], 0   ; face the way of the key
        mov     bx, dx                  ; BX = target speed = +limit ...
        cmp     cx, 0
        jg      .target_known
        mov     byte [hero_facing], 1
        neg     bx                      ; ... or -limit when going left
.target_known:
        mov     dx, WALK_ACCEL          ; DX = step: normal acceleration,
        cmp     ax, 0                   ; unless Mario moves the opposite way:
        je      .step_known             ; then brake harder
        jl      .moving_left
        cmp     cx, 0                   ; moving right, steering right: accelerate
        jg      .step_known
        jmp     short .brake            ; moving right, steering left
.moving_left:
        cmp     cx, 0                   ; moving left, steering left: accelerate
        jl      .step_known
.brake:
        mov     dx, BRAKE_ACCEL
.step_known:
        push    ax                      ; current speed
        push    bx                      ; target speed
        push    dx                      ; step
        call    MoveToward
.speed_done:
        mov     [hero_vx], ax

        ; ---- 3. jump: only from the ground, once per key press ----
        cmp     byte [key_state + SC_SPACE], 0
        je      .space_up
        cmp     byte [hero_jump_latch], 0
        jne     .gravity                ; this press was already used
        mov     byte [hero_jump_latch], 1
        cmp     byte [hero_on_ground], 0
        je      .gravity                ; in the air: no double jump
        mov     word [hero_vy], JUMP_START
        mov     byte [hero_on_ground], 0
        push    word sfx_jump           ; jump sound
        push    word 1
        call    PlaySfx
        jmp     short .gravity
.space_up:
        mov     byte [hero_jump_latch], 0       ; key released: ready again
        mov     ax, [hero_vy]
        cmp     ax, JUMP_CUTOFF         ; rising faster than the cut-off speed?
        jge     .gravity                ; (signed: more negative = faster up)
        mov     word [hero_vy], JUMP_CUTOFF     ; variable jump height

        ; ---- 4. gravity, limited to the maximum fall speed ----
.gravity:
        mov     ax, [hero_vy]
        add     ax, GRAVITY
        cmp     ax, MAX_FALL
        jle     .gravity_ok
        mov     ax, MAX_FALL
.gravity_ok:
        mov     [hero_vy], ax

        ; ---- 5. move sideways: position += speed (fraction first, then ADC) ----
        mov     dx, [hero_vx]
        add     byte [hero_xf], dl      ; fraction bytes; carry = one more pixel
        mov     al, dh
        cbw                             ; AX = whole pixels of the speed (signed)
        adc     [hero_x], ax            ; whole pixels + the carry
        mov     ax, [hero_x]
        cmp     ax, [camera_x]          ; left wall: the left edge of the screen
        jge     .left_ok
        mov     ax, [camera_x]
        mov     [hero_x], ax
        mov     byte [hero_xf], 0
        mov     word [hero_vx], 0
.left_ok:
        cmp     ax, LEVEL_PIXELS - TILE_SIZE    ; right wall: end of the level
        jl      .right_ok
        mov     word [hero_x], LEVEL_PIXELS - TILE_SIZE
        mov     byte [hero_xf], 0
        mov     word [hero_vx], 0
.right_ok:

        ; ---- 5b. wall in front (Section 5.6): sideways tile collision ----
        mov     ax, [hero_vx]
        or      ax, ax
        jz      .x_done
        js      .hit_left_test
        mov     ax, [hero_x]            ; moving right: test the right side
        add     ax, HIT_RIGHT
        push    ax
        call    HeroColumnSolid
        or      ax, ax
        jz      .x_done
        mov     ax, [hero_x]
        add     ax, HIT_RIGHT
        and     ax, 0FFF0h              ; left edge of the wall tile
        sub     ax, HIT_RIGHT + 1       ; our right side touches it
        jmp     short .x_stop
.hit_left_test:
        mov     ax, [hero_x]            ; moving left: test the left side
        add     ax, HIT_LEFT
        push    ax
        call    HeroColumnSolid
        or      ax, ax
        jz      .x_done
        mov     ax, [hero_x]
        add     ax, HIT_LEFT
        and     ax, 0FFF0h
        add     ax, TILE_SIZE - HIT_LEFT        ; right edge of the wall tile
.x_stop:
        mov     [hero_x], ax
        mov     byte [hero_xf], 0
        mov     word [hero_vx], 0       ; Place him against the wall, speed = 0
.x_done:

        ; ---- 6. move up / down, then tile collision (Section 5.6) ----
        mov     dx, [hero_vy]
        add     byte [hero_yf], dl
        mov     al, dh
        cbw
        adc     [hero_y], ax

        mov     cx, TILE_SIZE           ; CX = Mario's height: 16 or 32
        cmp     byte [hero_form], 0
        je      .height_known
        mov     cx, 2 * TILE_SIZE
.height_known:
        mov     byte [hero_on_ground], 0
        cmp     word [hero_vy], 0
        jl      .rising

        mov     ax, [hero_y]            ; falling: is there ground under the feet?
        push    ax
        call    HeroRowSolid
        or      ax, ax
        jz      .y_done
        mov     ax, [hero_y]
        and     ax, 0FFF0h              ; place him on top of the tile
        mov     [hero_y], ax
        mov     byte [hero_yf], 0
        mov     word [hero_vy], 0
        mov     byte [hero_on_ground], 1
        mov     word [stomp_chain], 0   ; landing ends the stomp chain
        jmp     short .y_done

.rising:
        mov     ax, [hero_y]            ; rising: is the head inside a tile?
        sub     ax, cx                  ; AX = y of the top of his head
        push    ax
        call    HeroRowSolid
        or      ax, ax
        jz      .y_done
        mov     ax, [hero_y]
        sub     ax, cx
        mov     [bump_y], ax            ; remember the hit for the block code
        mov     bx, [hero_x]
        add     bx, TILE_SIZE / 2       ; horizontal centre of his head
        mov     [bump_x], bx
        mov     byte [bump_flag], 1
        and     ax, 0FFF0h
        add     ax, TILE_SIZE           ; head just under the tile
        add     ax, cx                  ; feet = head + height
        mov     [hero_y], ax
        mov     byte [hero_yf], 0
        mov     word [hero_vy], 0       ; he starts falling
.y_done:

        ; ---- 7. pit: the top of Mario is below the bottom of the map ----
        mov     ax, [hero_y]
        sub     ax, cx
        cmp     ax, PIT_Y
        jl      .no_pit
        mov     byte [death_kind], 2    ; fell into a pit (kills at any health, no hop)
.no_pit:

        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret

; --------------------------------------------------------------------------
; HeroColumnSolid(px)
;   Purpose : is any tile along Mario's height solid at world x = px?
;             Samples at his feet, in the middle, and at his head so that
;             a 16 or 32 pixel tall body can never skip over a tile.
;   Inputs  : on the stack: px
;   Outputs : AX = 1 solid, 0 free
;   Changes : AX only
; --------------------------------------------------------------------------
HeroColumnSolid:
        push    bp
        mov     bp, sp
        push    bx
        ; [bp+4] = px
        mov     bx, [hero_y]
        dec     bx                      ; lowest pixel row of the feet
        push    word [bp+4]
        push    bx
        call    IsSolid
        or      ax, ax
        jnz     .done
        mov     bx, [hero_y]
        sub     bx, TILE_SIZE           ; one tile higher
        push    word [bp+4]
        push    bx
        call    IsSolid
        or      ax, ax
        jnz     .done
        cmp     byte [hero_form], 0
        je      .done                   ; Small: AX is 0 here
        mov     bx, [hero_y]
        sub     bx, 2 * TILE_SIZE       ; Super: top of the head
        push    word [bp+4]
        push    bx
        call    IsSolid
.done:
        pop     bx
        pop     bp
        ret     2

; --------------------------------------------------------------------------
; HeroRowSolid(py)
;   Purpose : is the tile under the left or the right side of Mario's body
;             solid at world y = py? (used for the feet and for the head)
;   Inputs  : on the stack: py
;   Outputs : AX = 1 solid, 0 free
;   Changes : AX only
; --------------------------------------------------------------------------
HeroRowSolid:
        push    bp
        mov     bp, sp
        ; [bp+4] = py
        mov     ax, [hero_x]
        add     ax, HIT_LEFT
        push    ax
        push    word [bp+4]
        call    IsSolid
        or      ax, ax
        jnz     .done
        mov     ax, [hero_x]
        add     ax, HIT_RIGHT
        push    ax
        push    word [bp+4]
        call    IsSolid
.done:
        pop     bp
        ret     2

; --------------------------------------------------------------------------
; IsSolid(px, py)
;   Purpose : can Mario stand on / not walk through the tile at this pixel?
;             Solid tiles are codes 1..10 (ground, bricks, "?" blocks, empty
;             block, pipes, stairs). Sky, coins and the flag are not solid.
;   Inputs  : on the stack, pushed in this order: px, py
;   Outputs : AX = 1 solid, 0 not solid
;   Changes : AX only
; --------------------------------------------------------------------------
IsSolid:
        push    bp
        mov     bp, sp
        ; [bp+4] = py, [bp+6] = px
        push    word [bp+6]
        push    word [bp+4]
        call    GetTile                 ; AX = tile code
        dec     ax                      ; code 0 becomes 0FFFFh (huge)
        cmp     ax, T_STAIR - 1         ; codes 1..10 -> 0..9
        mov     ax, 1                   ; (MOV keeps the flags)
        jbe     .done
        xor     ax, ax
.done:
        pop     bp
        ret     4

; --------------------------------------------------------------------------
; UpdateCamera  (Module 6, rule of Section 5.3)
;   Purpose : once per frame, after Mario moved: if he is right of the
;             middle of the screen the camera follows him; it never moves
;             back and stops at the end of the level.
;   Inputs  : none (reads hero_x, camera_x)
;   Outputs : camera_x
;   Changes : none
; --------------------------------------------------------------------------
UpdateCamera:
        push    ax
        mov     ax, [hero_x]
        sub     ax, CAMERA_FOLLOW_X     ; new camera = Mario x - 160
        jle     .done                   ; still left of the middle
        cmp     ax, CAMERA_MAX
        jle     .not_past_end
        mov     ax, CAMERA_MAX          ; limit: level width - 320
.not_past_end:
        cmp     ax, [camera_x]
        jle     .done                   ; never decrease the camera
        mov     [camera_x], ax
.done:
        pop     ax
        ret

; --------------------------------------------------------------------------
; HandleTestKeys
;   Purpose : debug keys (listed in the README): R = restart the level, C = +10
;             coins, T = 5 seconds left, 1 / 2 / 3 = jump to
;             x = 380, 640 or 752 (standing on the ground) to try the pipe,
;             the stairs and the pits without walking all the way.
;   Inputs  : none
;   Outputs : none
;   Changes : none
; --------------------------------------------------------------------------
HandleTestKeys:
        push    ax
        cmp     byte [key_state + SC_R], 0
        je      .not_r
        call    RestartLevel
.not_r:
        mov     al, [key_state + SC_C]  ; C (pressed once) = +10 coins, to test the 100-coin life
        cmp     al, [c_was_down]
        mov     [c_was_down], al
        je      .not_c
        or      al, al
        jz      .not_c
        push    cx
        mov     cx, 10
.ten_coins:
        call    AddCoin
        dec     cx
        jnz     .ten_coins
        pop     cx
.not_c:
        mov     al, [key_state + SC_T]  ; T (pressed once) = only 5 seconds left, to test the time-out
        cmp     al, [t_was_down]
        mov     [t_was_down], al
        je      .not_t
        or      al, al
        jz      .not_t
        cmp     word [level_clock], 5
        jbe     .not_t
        mov     word [level_clock], 5
.not_t:
        mov     ax, 976                 ; 1 = column 61
        cmp     byte [key_state + SC_1], 0
        jne     .go
        mov     ax, 1936                ; 2 = column 121
        cmp     byte [key_state + SC_2], 0
        jne     .go
        mov     ax, 2352                ; 3 = column 147
        cmp     byte [key_state + SC_3], 0
        je      .done
.go:
        mov     [hero_x], ax
        mov     byte [hero_xf], 0
        mov     word [hero_y], GROUND_Y
        mov     byte [hero_yf], 0
        mov     word [hero_vx], 0
        mov     word [hero_vy], 0
        sub     ax, CAMERA_FOLLOW_X     ; camera as if he had walked there
        jge     .cam_low_ok
        xor     ax, ax
.cam_low_ok:
        cmp     ax, CAMERA_MAX
        jle     .cam_ok
        mov     ax, CAMERA_MAX
.cam_ok:
        mov     [camera_x], ax
.done:
        pop     ax
        ret

; ==========================================================================
; MODULE 11 : ENEMIES AND SHELLS
; ==========================================================================
; Each enemy is one 16-byte record in enemy_table (see E_* in the constants).
; The update procedures walk through the table with a pointer in BX and use
; [BX + E_xxx] indexed addressing. A record whose type is 0 is unused/removed.
; ==========================================================================

; --------------------------------------------------------------------------
; AddScore(points)
;   Purpose : add points to the 32-bit score (ADD, then ADC for the high
;             word) and clamp it to 999,999.
;   Inputs  : on the stack: points (one word, 0..65535)
;   Outputs : score_lo, score_hi
;   Changes : none
; --------------------------------------------------------------------------
AddScore:
        push    bp
        mov     bp, sp
        push    ax
        ; [bp+4] = points
        mov     ax, [bp+4]
        add     [score_lo], ax
        adc     word [score_hi], 0      ; the carry moves into the high word
        cmp     word [score_hi], MAX_SCORE_HI
        jb      .done
        ja      .clamp
        cmp     word [score_lo], MAX_SCORE_LO
        jbe     .done
.clamp:
        mov     word [score_hi], MAX_SCORE_HI
        mov     word [score_lo], MAX_SCORE_LO
.done:
        pop     ax
        pop     bp
        ret     2

; --------------------------------------------------------------------------
; RectOverlap(ax, ay, aw, ah, bx, by, bw, bh)
;   Purpose : do two rectangles overlap? (signed coordinates)
;   Inputs  : on the stack, pushed in this order: ax, ay, aw, ah, bx, by, bw, bh
;   Outputs : AX = 1 if they overlap, 0 if not
;   Changes : AX only
; --------------------------------------------------------------------------
RectOverlap:
        push    bp
        mov     bp, sp
        push    bx
        ; [bp+4]=bh [bp+6]=bw [bp+8]=by [bp+10]=bx [bp+12]=ah [bp+14]=aw [bp+16]=ay [bp+18]=ax
        mov     ax, [bp+18]             ; a.x < b.x + b.w ?
        mov     bx, [bp+10]
        add     bx, [bp+6]
        cmp     ax, bx
        jge     .no
        mov     ax, [bp+10]             ; b.x < a.x + a.w ?
        mov     bx, [bp+18]
        add     bx, [bp+14]
        cmp     ax, bx
        jge     .no
        mov     ax, [bp+16]             ; a.y < b.y + b.h ?
        mov     bx, [bp+8]
        add     bx, [bp+4]
        cmp     ax, bx
        jge     .no
        mov     ax, [bp+8]              ; b.y < a.y + a.h ?
        mov     bx, [bp+16]
        add     bx, [bp+12]
        cmp     ax, bx
        jge     .no
        mov     ax, 1
        jmp     short .done
.no:
        xor     ax, ax
.done:
        pop     bx
        pop     bp
        ret     16

; --------------------------------------------------------------------------
; ResetEnemies
;   Purpose : copy the start table over the working table (one REP MOVSW),
;             so every enemy is back at its start, waiting.
;   Inputs  : none
;   Outputs : none
;   Changes : none
; --------------------------------------------------------------------------
ResetEnemies:
        push    cx
        push    si
        push    di
        push    es
        pushf
        push    ds
        pop     es                      ; ES = our segment
        cld
        mov     si, enemy_init
        mov     di, enemy_table
        mov     cx, MAX_ENEMIES * ENEMY_SIZE / 2
        rep movsw
        popf
        pop     es
        pop     di
        pop     si
        pop     cx
        ret

; --------------------------------------------------------------------------
; UpdateEnemies
;   Purpose : one frame for every enemy in the table (Section 5.13 step 4).
;   Inputs  : none
;   Outputs : the enemy table
;   Changes : none
; --------------------------------------------------------------------------
UpdateEnemies:
        push    bx
        push    cx
        mov     bx, enemy_table
        mov     cx, MAX_ENEMIES
.next:
        cmp     byte [bx + E_TYPE], ET_NONE
        je      .skip
        push    bx
        call    UpdateOneEnemy
.skip:
        add     bx, ENEMY_SIZE
        dec     cx
        jnz     .next
        pop     cx
        pop     bx
        ret

; --------------------------------------------------------------------------
; UpdateOneEnemy(record)
;   Purpose : activation, removal, walking / sliding, turning and falling of
;             one enemy (rules of Section 5.5).
;   Inputs  : on the stack: address of the record
;   Outputs : the record
;   Changes : none
; --------------------------------------------------------------------------
UpdateOneEnemy:
        push    bp
        mov     bp, sp
        push    ax
        push    bx
        ; [bp+4] = record
        mov     bx, [bp+4]
        mov     ax, [bx + E_X]
        sub     ax, [camera_x]          ; AX = screen x (signed)
        cmp     ax, -32
        jl      .remove                 ; more than 32 pixels left of the screen
        cmp     byte [bx + E_STATE], ES_WAIT
        jne     .active
        cmp     ax, SCREEN_W + TILE_SIZE
        jge     .done                   ; still further than one tile away: stand still
        mov     byte [bx + E_STATE], ES_WALK
.active:
        cmp     byte [bx + E_GRACE], 0
        je      .grace_done
        dec     byte [bx + E_GRACE]
.grace_done:
        cmp     byte [bx + E_TYPE], ET_MUSHROOM
        jne     .not_mushroom
        cmp     byte [bx + E_STATE], ES_EMERGE
        jne     .mushroom_moves
        dec     word [bx + E_Y]         ; rising out of the block, 1 pixel per frame
        dec     word [bx + E_TIMER]
        jnz     .done
        mov     byte [bx + E_STATE], ES_WALK    ; on top of the block: moves right
        mov     byte [bx + E_DIR], 0
        jmp     short .done
.mushroom_moves:
        push    bx
        push    word MUSHROOM_SPEED
        push    word 0                  ; flags: only walls turn it round
        call    EnemyStep
        jmp     short .fall
.not_mushroom:
        cmp     byte [bx + E_TYPE], ET_WALKER
        jne     .snail
        cmp     byte [bx + E_STATE], ES_FLAT
        jne     .walker_walks
        dec     word [bx + E_TIMER]     ; flattened: wait about 1 second, then go
        jnz     .done
        jmp     short .remove
.walker_walks:
        push    bx
        push    word GOOMBA_SPEED
        push    word WALKER_FLAGS       ; turn at other enemies (and at platform edges)
        call    EnemyStep
        jmp     short .fall
.snail:
        mov     al, [bx + E_STATE]
        cmp     al, ES_SHELL
        je      .fall                   ; stationary shell: only gravity
        cmp     al, ES_SLIDE
        je      .slide
        push    bx
        push    word KOOPA_SPEED
        push    word 3                  ; flags: turn at platform edges and enemies
        call    EnemyStep
        jmp     short .fall
.slide:
        push    bx
        push    word SHELL_SPEED
        push    word 0                  ; a shell only bounces off walls
        call    EnemyStep
        push    bx
        call    EnemyShellKills
.fall:
        push    bx
        call    EnemyFall
        jmp     short .done
.remove:
        mov     byte [bx + E_TYPE], ET_NONE
.done:
        pop     bx
        pop     ax
        pop     bp
        ret     2

; --------------------------------------------------------------------------
; EnemyStep(record, speed, flags)
;   Purpose : move one enemy sideways by its speed in its direction. If a wall
;             (or, by the flags, a platform edge or another enemy) is in the
;             way it turns around instead of moving.
;   Inputs  : on the stack, pushed in this order: record, speed (8.8,
;             positive), flags (bit 0 = turn at platform edges, bit 1 = turn
;             at other enemies)
;   Outputs : the record
;   Changes : none
; --------------------------------------------------------------------------
EnemyStep:
        push    bp
        mov     bp, sp
        push    ax
        push    bx
        push    cx
        push    dx
        push    si
        ; [bp+4] = flags, [bp+6] = speed, [bp+8] = record
        mov     bx, [bp+8]
        mov     dx, [bp+6]
        cmp     byte [bx + E_DIR], 0
        je      .dir_known
        neg     dx                      ; going left: negative speed
.dir_known:
        mov     al, [bx + E_XF]
        add     al, dl                  ; fraction first; the carry is kept
        mov     cl, al                  ; CL = new fraction
        mov     al, dh
        cbw                             ; AX = whole pixels of the speed (signed)
        adc     ax, [bx + E_X]          ; plus the carry
        mov     si, ax                  ; SI = candidate x

        push    bx
        push    si
        call    EnemyWallAt
        or      ax, ax
        jnz     .turn
        test    word [bp+4], 1
        jz      .no_edge_check
        cmp     byte [bx + E_GND], 0
        je      .no_edge_check          ; in the air: nothing to fall off
        push    bx
        push    si
        call    EnemyFloorAt
        or      ax, ax
        jz      .turn                   ; no floor in front of the feet
.no_edge_check:
        test    word [bp+4], 2
        jz      .go
        push    bx
        push    si
        call    EnemyBlocked
        or      ax, ax
        jnz     .turn
.go:
        mov     [bx + E_X], si
        mov     [bx + E_XF], cl
        jmp     short .done
.turn:
        xor     byte [bx + E_DIR], 1    ; turn around, no step this frame
.done:
        pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        pop     bp
        ret     6

; --------------------------------------------------------------------------
; EnemyWallAt(record, x)
;   Purpose : is there a solid tile in front of the enemy if it stood at x?
;             (tests the front edge at the feet and at the top)
;   Inputs  : on the stack, pushed in this order: record, x
;   Outputs : AX = 1 wall, 0 free
;   Changes : AX only
; --------------------------------------------------------------------------
EnemyWallAt:
        push    bp
        mov     bp, sp
        push    bx
        push    cx
        push    dx
        ; [bp+4] = x, [bp+6] = record
        mov     bx, [bp+6]
        mov     cx, [bp+4]
        cmp     byte [bx + E_DIR], 0
        jne     .left
        add     cx, HIT_RIGHT           ; moving right: the right edge
        jmp     short .edge
.left:
        add     cx, HIT_LEFT            ; moving left: the left edge
.edge:
        mov     dx, [bx + E_Y]
        dec     dx                      ; lowest pixel row
        push    cx
        push    dx
        call    IsSolid
        or      ax, ax
        jnz     .done
        mov     dx, [bx + E_Y]
        sub     dx, TILE_SIZE           ; top pixel row
        push    cx
        push    dx
        call    IsSolid
.done:
        pop     dx
        pop     cx
        pop     bx
        pop     bp
        ret     4

; --------------------------------------------------------------------------
; EnemyFloorAt(record, x)
;   Purpose : is there floor under the front foot if the enemy stood at x?
;   Inputs  : on the stack, pushed in this order: record, x
;   Outputs : AX = 1 floor, 0 nothing (a ledge or a pit)
;   Changes : AX only
; --------------------------------------------------------------------------
EnemyFloorAt:
        push    bp
        mov     bp, sp
        push    bx
        push    cx
        ; [bp+4] = x, [bp+6] = record
        mov     bx, [bp+6]
        mov     cx, [bp+4]
        cmp     byte [bx + E_DIR], 0
        jne     .left
        add     cx, HIT_RIGHT
        jmp     short .test
.left:
        add     cx, HIT_LEFT
.test:
        push    cx
        push    word [bx + E_Y]         ; the pixel row just under the feet
        call    IsSolid
        pop     cx
        pop     bx
        pop     bp
        ret     4

; --------------------------------------------------------------------------
; EnemyBlocked(record, x)
;   Purpose : is another enemy standing in front of this one (overlapping it
;             if it stood at x)? Flattened walkers, waiting enemies and
;             sliding shells do not count.
;   Inputs  : on the stack, pushed in this order: record, x
;   Outputs : AX = 1 blocked, 0 free
;   Changes : AX only
; --------------------------------------------------------------------------
EnemyBlocked:
        push    bp
        mov     bp, sp
        push    bx
        push    cx
        push    si
        ; [bp+4] = x, [bp+6] = record
        mov     bx, [bp+6]
        mov     si, enemy_table
        mov     cx, MAX_ENEMIES
.next:
        cmp     si, bx
        je      .skip                   ; not ourselves
        cmp     byte [si + E_TYPE], ET_NONE
        je      .skip
        cmp     byte [si + E_TYPE], ET_MUSHROOM
        je      .skip                   ; a mushroom is not an enemy
        mov     al, [si + E_STATE]
        cmp     al, ES_WALK
        je      .candidate
        cmp     al, ES_SHELL            ; a stationary shell blocks too ...
        jne     .skip
        cmp     byte [si + E_TYPE], ET_SNAIL
        jne     .skip                   ; ... but a flat walker does not
.candidate:
        mov     ax, [si + E_X]
        cmp     byte [bx + E_DIR], 0
        je      .ahead_right
        cmp     ax, [bx + E_X]
        jge     .skip                   ; going left: it must be on our left
        jmp     short .test
.ahead_right:
        cmp     ax, [bx + E_X]
        jle     .skip                   ; going right: it must be on our right
.test:
        mov     ax, [bp+4]
        add     ax, 2
        push    ax                      ; our rectangle at the new x
        mov     ax, [bx + E_Y]
        sub     ax, TILE_SIZE
        push    ax
        push    word 12
        push    word TILE_SIZE
        mov     ax, [si + E_X]
        add     ax, 2
        push    ax                      ; the other rectangle
        mov     ax, [si + E_Y]
        sub     ax, TILE_SIZE
        push    ax
        push    word 12
        push    word TILE_SIZE
        call    RectOverlap
        or      ax, ax
        jnz     .done                   ; AX = 1
.skip:
        add     si, ENEMY_SIZE
        dec     cx
        jnz     .next
        xor     ax, ax
.done:
        pop     si
        pop     cx
        pop     bx
        pop     bp
        ret     4

; --------------------------------------------------------------------------
; EnemyFall(record)
;   Purpose : gravity for one enemy: speed up (to the maximum fall speed),
;             move down, land on solid tiles; removed below the map.
;   Inputs  : on the stack: record
;   Outputs : the record
;   Changes : none
; --------------------------------------------------------------------------
EnemyFall:
        push    bp
        mov     bp, sp
        push    ax
        push    bx
        push    dx
        ; [bp+4] = record
        mov     bx, [bp+4]
        mov     dx, [bx + E_VY]
        add     dx, GRAVITY
        cmp     dx, MAX_FALL
        jle     .speed_ok
        mov     dx, MAX_FALL
.speed_ok:
        mov     [bx + E_VY], dx
        add     byte [bx + E_YF], dl    ; fraction first, then the carry
        mov     al, dh
        cbw
        adc     [bx + E_Y], ax

        mov     byte [bx + E_GND], 0
        mov     ax, [bx + E_X]
        add     ax, HIT_LEFT
        push    ax
        push    word [bx + E_Y]
        call    IsSolid
        or      ax, ax
        jnz     .land
        mov     ax, [bx + E_X]
        add     ax, HIT_RIGHT
        push    ax
        push    word [bx + E_Y]
        call    IsSolid
        or      ax, ax
        jz      .air
.land:
        mov     ax, [bx + E_Y]
        and     ax, 0FFF0h              ; on top of the tile
        mov     [bx + E_Y], ax
        mov     byte [bx + E_YF], 0
        mov     word [bx + E_VY], 0
        mov     byte [bx + E_GND], 1
        jmp     short .done
.air:
        cmp     word [bx + E_Y], MAP_ROWS * TILE_SIZE + TILE_SIZE
        jl      .done
        mov     byte [bx + E_TYPE], ET_NONE     ; fell below the map
.done:
        pop     dx
        pop     bx
        pop     ax
        pop     bp
        ret     2

; --------------------------------------------------------------------------
; EnemyShellKills(record)
;   Purpose : a sliding shell removes every walker or snail it touches
;             (+500 points each).
;   Inputs  : on the stack: record of the sliding shell
;   Outputs : the table, the score
;   Changes : none
; --------------------------------------------------------------------------
EnemyShellKills:
        push    bp
        mov     bp, sp
        push    ax
        push    bx
        push    cx
        push    si
        ; [bp+4] = record
        mov     bx, [bp+4]
        mov     si, enemy_table
        mov     cx, MAX_ENEMIES
.next:
        cmp     si, bx
        je      .skip
        cmp     byte [si + E_TYPE], ET_NONE
        je      .skip
        cmp     byte [si + E_TYPE], ET_MUSHROOM
        je      .skip                   ; a mushroom is not an enemy
        cmp     byte [si + E_STATE], ES_WAIT
        je      .skip
        cmp     byte [si + E_TYPE], ET_WALKER
        jne     .candidate
        cmp     byte [si + E_STATE], ES_FLAT
        je      .skip                   ; already flattened
.candidate:
        mov     ax, [bx + E_X]
        add     ax, 2
        push    ax
        mov     ax, [bx + E_Y]
        sub     ax, TILE_SIZE
        push    ax
        push    word 12
        push    word TILE_SIZE
        mov     ax, [si + E_X]
        add     ax, 2
        push    ax
        mov     ax, [si + E_Y]
        sub     ax, TILE_SIZE
        push    ax
        push    word 12
        push    word TILE_SIZE
        call    RectOverlap
        or      ax, ax
        jz      .skip
        mov     byte [si + E_TYPE], ET_NONE     ; removed
        push    word 500
        call    AddScore
.skip:
        add     si, ENEMY_SIZE
        dec     cx
        jnz     .next
        pop     si
        pop     cx
        pop     bx
        pop     ax
        pop     bp
        ret     2

; --------------------------------------------------------------------------
; ResolveEnemies
;   Purpose : Mario against every enemy (Section 5.13 step 5): rectangle
;             overlap, then HandleContact decides stomp, kick or hurt.
;   Inputs  : none
;   Outputs : table, score, Mario
;   Changes : none
; --------------------------------------------------------------------------
ResolveEnemies:
        push    ax
        push    bx
        push    cx
        push    si
        mov     bx, enemy_table
        mov     si, MAX_ENEMIES
.next:
        cmp     byte [bx + E_TYPE], ET_NONE
        je      .skip
        cmp     byte [bx + E_STATE], ES_WAIT
        je      .skip
        cmp     byte [bx + E_STATE], ES_EMERGE
        je      .skip                   ; still inside its block
        cmp     byte [bx + E_TYPE], ET_WALKER
        jne     .live
        cmp     byte [bx + E_STATE], ES_FLAT
        je      .skip                   ; a flat walker is harmless
.live:
        mov     cx, TILE_SIZE           ; Mario's height
        cmp     byte [hero_form], 0
        je      .height_known
        mov     cx, 2 * TILE_SIZE
.height_known:
        mov     ax, [hero_x]
        add     ax, HIT_LEFT
        push    ax                      ; Mario's rectangle
        mov     ax, [hero_y]
        sub     ax, cx
        push    ax
        push    word 12
        push    cx
        mov     ax, [bx + E_X]
        add     ax, 2
        push    ax                      ; the enemy's rectangle
        mov     ax, [bx + E_Y]
        sub     ax, TILE_SIZE
        push    ax
        push    word 12
        push    word TILE_SIZE
        call    RectOverlap
        or      ax, ax
        jz      .skip
        cmp     byte [bx + E_TYPE], ET_MUSHROOM
        jne     .contact
        push    bx
        call    CollectMushroom         ; power-up: no stomp, no damage
        jmp     short .skip
.contact:
        push    bx
        call    HandleContact
.skip:
        add     bx, ENEMY_SIZE
        dec     si
        jnz     .next
        pop     si
        pop     cx
        pop     bx
        pop     ax
        ret

; --------------------------------------------------------------------------
; HandleContact(record)
;   Purpose : Mario touches an enemy: the outcome table of Section 5.6.
;             Stomp = Mario moves down and his feet were above the upper
;             half of the enemy in the previous frame.
;   Inputs  : on the stack: record of the enemy
;   Outputs : record, score, Mario
;   Changes : none
; --------------------------------------------------------------------------
HandleContact:
        push    bp
        mov     bp, sp
        push    ax
        push    bx
        push    dx
        ; [bp+4] = record
        mov     bx, [bp+4]
        xor     dl, dl                  ; DL = 1 when this is a stomp
        cmp     word [hero_vy], 0
        jle     .stomp_known            ; not moving down
        mov     ax, [bx + E_Y]
        sub     ax, TILE_SIZE / 2       ; the middle of the enemy
        cmp     [hero_prev_y], ax
        jg      .stomp_known            ; feet were not above the upper half
        mov     dl, 1
.stomp_known:
        mov     al, [bx + E_STATE]
        cmp     byte [bx + E_TYPE], ET_WALKER
        jne     .snail
        or      dl, dl                  ; walker, walking
        jz      .hurt
        mov     byte [bx + E_STATE], ES_FLAT
        mov     word [bx + E_TIMER], FLAT_TICKS
        call    StompReward
        jmp     short .done
.snail:
        cmp     al, ES_WALK
        jne     .shell
        or      dl, dl                  ; snail, walking: becomes a shell
        jz      .hurt
        mov     byte [bx + E_STATE], ES_SHELL
        mov     byte [bx + E_GRACE], KICK_GRACE
        call    StompReward
        jmp     short .done
.shell:
        cmp     byte [bx + E_GRACE], 0
        jne     .done                   ; ignoring Mario for a few frames
        cmp     al, ES_SLIDE
        je      .sliding
        push    word 400                ; stationary shell: kick it, +400
        call    AddScore
        mov     byte [bx + E_DIR], 1    ; it slides away from Mario
        mov     ax, [hero_x]
        cmp     ax, [bx + E_X]
        jge     .dir_set
        mov     byte [bx + E_DIR], 0
.dir_set:
        mov     byte [bx + E_STATE], ES_SLIDE
        mov     byte [bx + E_GRACE], KICK_GRACE
        or      dl, dl
        jz      .done
        call    StompBounce             ; kicked from above: Mario bounces
        jmp     short .done
.sliding:
        or      dl, dl                  ; sliding shell: stomp stops it
        jz      .hurt
        mov     byte [bx + E_STATE], ES_SHELL
        mov     byte [bx + E_GRACE], KICK_GRACE
        call    StompReward
        jmp     short .done
.hurt:
        call    HeroHurt
.done:
        pop     dx
        pop     bx
        pop     ax
        pop     bp
        ret     2

; --------------------------------------------------------------------------
; StompReward
;   Purpose : points for a stomp from the chain table (100, 200, 400, 500,
;             800, 1000, 2000, 4000, 5000, 8000, then a 1-UP), chain + 1,
;             and Mario bounces.
;   Inputs  : none
;   Outputs : score / lives, stomp_chain, hero_vy
;   Changes : none
; --------------------------------------------------------------------------
StompReward:
        push    ax
        push    bx
        mov     bx, [stomp_chain]
        cmp     bx, 10
        jae     .one_up
        shl     bx, 1                   ; word table
        push    word [stomp_points + bx]
        call    AddScore
        jmp     short .count
.one_up:
        cmp     byte [lives], MAX_LIVES
        jae     .count
        inc     byte [lives]
.count:
        cmp     word [stomp_chain], 255
        jae     .bounce
        inc     word [stomp_chain]
.bounce:
        call    StompBounce
        pop     bx
        pop     ax
        ret

; --------------------------------------------------------------------------
; StompBounce
;   Purpose : Mario bounces up; higher when the jump key is held.
;   Inputs  : none
;   Outputs : hero_vy, hero_on_ground
;   Changes : none
; --------------------------------------------------------------------------
StompBounce:
        push    word sfx_stomp          ; stomp / kick sound (highest priority)
        push    word 3
        call    PlaySfx
        mov     word [hero_vy], STOMP_BOUNCE
        cmp     byte [key_state + SC_SPACE], 0
        je      .low
        mov     word [hero_vy], JUMP_START
.low:
        mov     byte [hero_on_ground], 0
        ret

; --------------------------------------------------------------------------
; HeroHurt
;   Purpose : Section 5.7: ignored while invulnerable; Super Mario becomes
;             Small and is invulnerable for 2 seconds; Small Mario dies
;             (Stage 10 stand-in: everything restarts; the real death
;             sequence is Module 14).
;   Inputs  : none
;   Outputs : hero variables
;   Changes : none
; --------------------------------------------------------------------------
HeroHurt:
        cmp     word [hero_invuln], 0
        jne     .done
        cmp     byte [hero_form], 0
        je      .dies
        mov     byte [hero_form], 0
        mov     byte [hero_hp], 1
        mov     word [hero_invuln], INVULN_TICKS
.done:
        ret
.dies:
        cmp     byte [death_kind], 0
        jne     .dead_already
        mov     byte [death_kind], 1    ; Mario dies: the Playing state starts the death animation
.dead_already:
        ret

; --------------------------------------------------------------------------
; DrawEnemies
;   Purpose : draw every visible enemy (-16 < screen x < 320) into the frame
;             buffer: walkers (two walk pictures, flat), snails (two walk
;             pictures, mirrored when walking left) and shells.
;   Inputs  : ES = frame buffer segment
;   Outputs : none
;   Changes : none
; --------------------------------------------------------------------------
DrawEnemies:
        push    ax
        push    bx
        push    cx
        push    dx
        push    si
        push    di
        mov     bx, enemy_table
        mov     di, MAX_ENEMIES
.next:
        cmp     byte [bx + E_TYPE], ET_NONE
        je      .skip
        mov     ax, [bx + E_X]
        sub     ax, [camera_x]          ; screen x
        cmp     ax, -TILE_SIZE
        jle     .skip
        cmp     ax, SCREEN_W
        jge     .skip
        mov     dx, ax                  ; DX = screen x
        xor     cx, cx                  ; flags
        mov     si, [tick_count]
        shr     si, 3
        and     si, 1                   ; walking picture 0 / 1
        cmp     byte [bx + E_TYPE], ET_MUSHROOM
        jne     .not_mushroom
        cmp     byte [bx + E_STATE], ES_EMERGE
        je      .skip                   ; drawn earlier, behind the block
        mov     ax, spr_mushroom
        jmp     short .picture
.not_mushroom:
        cmp     byte [bx + E_TYPE], ET_WALKER
        jne     .snail
        mov     ax, spr_walker_a
        or      si, si
        jz      .picture
        mov     ax, spr_walker_b
        cmp     byte [bx + E_STATE], ES_FLAT
        jne     .picture
        mov     ax, spr_walker_flat
        jmp     short .picture
.snail:
        cmp     byte [bx + E_STATE], ES_WALK
        jne     .shell_picture
        mov     ax, spr_snail_a
        or      si, si
        jz      .snail_dir
        mov     ax, spr_snail_b
.snail_dir:
        cmp     byte [bx + E_DIR], 0
        je      .picture
        or      cx, FLAG_MIRROR         ; the pictures face right
        jmp     short .picture
.shell_picture:
        mov     ax, spr_shell
.picture:
        mov     si, ax                  ; SI = bitmap
        cmp     byte [bx + E_TYPE], ET_WALKER
        jne     .not_flat
        cmp     byte [bx + E_STATE], ES_FLAT
        jne     .not_flat
        mov     si, spr_walker_flat
.not_flat:
        mov     ax, [bx + E_Y]
        sub     ax, TILE_SIZE           ; top = feet - 16
        push    dx
        push    ax
        push    si
        push    cx
        call    DrawSprite
.skip:
        add     bx, ENEMY_SIZE
        dec     di
        jnz     .next
        pop     di
        pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret

; ==========================================================================
; MODULE 12 : BLOCKS, COINS AND POWER-UPS  (Section 5.9)
; ==========================================================================

; --------------------------------------------------------------------------
; RestartLevel
;   Purpose : put the whole level back (map, Mario, enemies, effects, camera).
;             Score and coins are kept. Used after a death and by the R key.
;   Inputs  : none
;   Outputs : none
;   Changes : none
; --------------------------------------------------------------------------
RestartLevel:
        mov     byte [death_kind], 0
        mov     byte [bump_flag], 0     ; a head hit of the old life must not trigger anything
        call    ResetMap
        call    ResetHero
        call    ResetEnemies
        call    ResetFx
        call    ResetClock
        mov     word [camera_x], 0
        push    word 1                  ; the background music starts (loops)
        push    word mus_background
        call    MusicStart
        ret

; --------------------------------------------------------------------------
; GiveLife
;   Purpose : one more life, never above 99.
;   Inputs  : none
;   Outputs : lives
;   Changes : none
; --------------------------------------------------------------------------
GiveLife:
        cmp     byte [lives], MAX_LIVES
        jae     .done
        inc     byte [lives]
.done:
        ret

; --------------------------------------------------------------------------
; AddCoin
;   Purpose : coins + 1. At 100 coins the counter goes back to 0 and Mario
;             gets a life (no points for the life itself).
;   Inputs  : none
;   Outputs : coins, lives
;   Changes : none
; --------------------------------------------------------------------------
AddCoin:
        push    word sfx_coin           ; coin sound
        push    word 2
        call    PlaySfx
        inc     byte [coins]
        cmp     byte [coins], 100
        jb      .done
        mov     byte [coins], 0
        call    GiveLife
.done:
        ret

; --------------------------------------------------------------------------
; CoinReward
;   Purpose : a coin was collected or came out of a block: +200 points and
;             coins + 1.
;   Inputs  : none
;   Outputs : score, coins, lives
;   Changes : none
; --------------------------------------------------------------------------
CoinReward:
        push    word 200
        call    AddScore
        call    AddCoin
        ret

; --------------------------------------------------------------------------
; ResolveBlocks
;   Purpose : if Mario's head hit a tile this frame (bump_flag), look at the
;             tile under the middle of his head (Section 5.9):
;             brick: Small nothing; Super breaks it (+50, tile becomes sky)
;             "?" with a coin: becomes empty, coin pops out (+200, coins+1)
;             "?" with a mushroom: becomes empty, a mushroom appears on top
;             empty block: nothing.
;   Inputs  : none (reads bump_flag, bump_x, bump_y)
;   Outputs : the working map, score, coins, enemy table, effects
;   Changes : none
; --------------------------------------------------------------------------
ResolveBlocks:
        push    ax
        cmp     byte [bump_flag], 0
        je      .done
        push    word [bump_x]
        push    word [bump_y]
        call    GetTile                 ; AX = the tile that was hit
        cmp     ax, T_BRICK
        je      .brick
        cmp     ax, T_QBLOCK_COIN
        je      .coin_block
        cmp     ax, T_QBLOCK_MUSH
        je      .mushroom_block
        jmp     short .done             ; sky, ground, empty block ...: nothing
.brick:
        cmp     byte [hero_form], 0
        je      .done                   ; Small Mario: nothing, no points
        push    word [bump_x]
        push    word [bump_y]
        push    word T_SKY
        call    SetTile                 ; the brick is destroyed
        push    word 50
        call    AddScore
        jmp     short .done
.coin_block:
        push    word [bump_x]
        push    word [bump_y]
        push    word T_EMPTY
        call    SetTile
        call    CoinReward
        mov     ax, [bump_x]
        and     ax, 0FFF0h
        push    ax                      ; x of the block
        mov     ax, [bump_y]
        and     ax, 0FFF0h
        push    ax                      ; y of the block (the coin starts there)
        call    SpawnCoinFx
        jmp     short .done
.mushroom_block:
        push    word [bump_x]
        push    word [bump_y]
        push    word T_EMPTY
        call    SetTile
        push    word [bump_x]
        push    word [bump_y]
        call    SpawnMushroom
.done:
        pop     ax
        ret

; --------------------------------------------------------------------------
; SpawnMushroom(x, y)
;   Purpose : put a mushroom into a free enemy slot, hidden inside the block
;             at pixel (x, y); it rises out of the top of the block.
;   Inputs  : on the stack, pushed in this order: x, y (any pixel of the block)
;   Outputs : the enemy table (nothing happens when the table is full)
;   Changes : none
; --------------------------------------------------------------------------
SpawnMushroom:
        push    bp
        mov     bp, sp
        push    ax
        push    bx
        push    cx
        ; [bp+4] = y, [bp+6] = x
        mov     bx, enemy_table
        mov     cx, MAX_ENEMIES
.find:
        cmp     byte [bx + E_TYPE], ET_NONE
        je      .found
        add     bx, ENEMY_SIZE
        dec     cx
        jnz     .find
        jmp     short .done             ; no free slot
.found:
        mov     ax, [bp+6]
        and     ax, 0FFF0h
        mov     [bx + E_X], ax          ; same column as the block
        mov     ax, [bp+4]
        and     ax, 0FFF0h
        add     ax, TILE_SIZE
        mov     [bx + E_Y], ax          ; feet at the bottom of the block (hidden)
        mov     byte [bx + E_TYPE], ET_MUSHROOM
        mov     byte [bx + E_STATE], ES_EMERGE
        mov     byte [bx + E_XF], 0
        mov     byte [bx + E_DIR], 0
        mov     byte [bx + E_YF], 0
        mov     byte [bx + E_GND], 0
        mov     word [bx + E_VY], 0
        mov     word [bx + E_TIMER], TILE_SIZE  ; 16 frames to rise 16 pixels
        mov     byte [bx + E_GRACE], 0
.done:
        pop     cx
        pop     bx
        pop     ax
        pop     bp
        ret     4

; --------------------------------------------------------------------------
; CollectMushroom(record)
;   Purpose : Mario touched a mushroom: it is removed, +1000 points, and a
;             Small Mario becomes Super (health 2). His feet stay where they
;             are (hero_y is the feet), so the sprite grows upwards.
;   Inputs  : on the stack: record
;   Outputs : record, score, hero_form, hero_hp
;   Changes : none
; --------------------------------------------------------------------------
CollectMushroom:
        push    bp
        mov     bp, sp
        push    bx
        mov     bx, [bp+4]
        mov     byte [bx + E_TYPE], ET_NONE
        push    word 1000
        call    AddScore
        push    word sfx_power          ; power-up sound
        push    word 2
        call    PlaySfx
        cmp     byte [hero_form], 0
        jne     .done                   ; already Super: only the points
        mov     byte [hero_form], 1
        mov     byte [hero_hp], 2
.done:
        pop     bx
        pop     bp
        ret     2

; --------------------------------------------------------------------------
; CollectCoins
;   Purpose : free coins on the map: every coin tile that Mario's body
;             overlaps is collected (+200, coins + 1, tile becomes sky).
;             Looks at three columns across his body and a row every 8 pixels
;             from his feet to his head.
;   Inputs  : none
;   Outputs : the working map, score, coins, lives
;   Changes : none
; --------------------------------------------------------------------------
CollectCoins:
        push    ax
        push    bx
        push    cx
        mov     bx, [hero_y]
        dec     bx                      ; BX = pixel row being tested, from the feet up
        mov     cx, [hero_y]
        sub     cx, TILE_SIZE
        cmp     byte [hero_form], 0
        je      .top_known
        sub     cx, TILE_SIZE           ; CX = top pixel row of his head
.top_known:
.row:
        mov     ax, [hero_x]
        add     ax, HIT_LEFT
        push    ax
        push    bx
        call    CollectCoinAt
        mov     ax, [hero_x]
        add     ax, TILE_SIZE / 2
        push    ax
        push    bx
        call    CollectCoinAt
        mov     ax, [hero_x]
        add     ax, HIT_RIGHT
        push    ax
        push    bx
        call    CollectCoinAt
        cmp     bx, cx
        jle     .done                   ; that was the top row
        sub     bx, 8
        cmp     bx, cx
        jge     .row
        mov     bx, cx                  ; last row: exactly the top of his head
        jmp     short .row
.done:
        pop     cx
        pop     bx
        pop     ax
        ret

; --------------------------------------------------------------------------
; CollectCoinAt(px, py)
;   Purpose : if the tile at this pixel is a free coin, collect it.
;   Inputs  : on the stack, pushed in this order: px, py
;   Outputs : the working map, score, coins, lives
;   Changes : none
; --------------------------------------------------------------------------
CollectCoinAt:
        push    bp
        mov     bp, sp
        push    ax
        ; [bp+4] = py, [bp+6] = px
        push    word [bp+6]
        push    word [bp+4]
        call    GetTile
        cmp     ax, T_COIN
        jne     .done
        push    word [bp+6]
        push    word [bp+4]
        push    word T_SKY
        call    SetTile                 ; the coin disappears from the working map
        call    CoinReward
.done:
        pop     ax
        pop     bp
        ret     4

; --------------------------------------------------------------------------
; Effects: a coin that jumps out of a "?" block (record of FX_SIZE bytes:
;   +0 active, +1 frames left, +2 x, +4 y)
; --------------------------------------------------------------------------

; ResetFx : no effects active.   Inputs/Outputs/Changes: none
ResetFx:
        push    bx
        push    cx
        xor     bx, bx
        mov     cx, MAX_FX
.next:
        mov     byte [fx_table + bx], 0
        add     bx, FX_SIZE
        dec     cx
        jnz     .next
        pop     cx
        pop     bx
        ret

; SpawnCoinFx(x, y) : start a coin popping out at the block (x, y).
;   Inputs: on the stack: x, y.  Outputs: fx_table (ignored when full).  Changes: none
SpawnCoinFx:
        push    bp
        mov     bp, sp
        push    ax
        push    bx
        push    cx
        xor     bx, bx
        mov     cx, MAX_FX
.next:
        cmp     byte [fx_table + bx], 0
        je      .found
        add     bx, FX_SIZE
        dec     cx
        jnz     .next
        jmp     short .done
.found:
        mov     byte [fx_table + bx], 1
        mov     byte [fx_table + bx + 1], 12
        mov     ax, [bp+6]
        mov     [fx_table + bx + 2], ax
        mov     ax, [bp+4]
        mov     [fx_table + bx + 4], ax
.done:
        pop     cx
        pop     bx
        pop     ax
        pop     bp
        ret     4

; UpdateFx : move every active coin effect up 4 pixels; gone after 12 frames.
;   Inputs/Outputs/Changes: the effect table only
UpdateFx:
        push    bx
        push    cx
        xor     bx, bx
        mov     cx, MAX_FX
.next:
        cmp     byte [fx_table + bx], 0
        je      .skip
        sub     word [fx_table + bx + 4], 4
        dec     byte [fx_table + bx + 1]
        jnz     .skip
        mov     byte [fx_table + bx], 0
.skip:
        add     bx, FX_SIZE
        dec     cx
        jnz     .next
        pop     cx
        pop     bx
        ret

; DrawFx : draw the active coin effects.   Inputs: ES = frame buffer.  Changes: none
DrawFx:
        push    ax
        push    bx
        push    cx
        xor     bx, bx
        mov     cx, MAX_FX
.next:
        cmp     byte [fx_table + bx], 0
        je      .skip
        mov     ax, [fx_table + bx + 2]
        sub     ax, [camera_x]          ; screen x
        cmp     ax, -TILE_SIZE
        jle     .skip
        cmp     ax, SCREEN_W
        jge     .skip
        push    ax
        push    word [fx_table + bx + 4]
        push    word spr_coin
        push    word 0
        call    DrawSprite
.skip:
        add     bx, FX_SIZE
        dec     cx
        jnz     .next
        pop     cx
        pop     bx
        pop     ax
        ret

; DrawEmerging : mushrooms still rising out of their block. Drawn BEFORE the
;   map, so the block (drawn over it) hides the part that is still inside.
;   Inputs: ES = frame buffer.  Changes: none
DrawEmerging:
        push    ax
        push    bx
        push    cx
        mov     bx, enemy_table
        mov     cx, MAX_ENEMIES
.next:
        cmp     byte [bx + E_TYPE], ET_MUSHROOM
        jne     .skip
        cmp     byte [bx + E_STATE], ES_EMERGE
        jne     .skip
        mov     ax, [bx + E_X]
        sub     ax, [camera_x]
        cmp     ax, -TILE_SIZE
        jle     .skip
        cmp     ax, SCREEN_W
        jge     .skip
        push    ax
        mov     ax, [bx + E_Y]
        sub     ax, TILE_SIZE
        push    ax
        push    word spr_mushroom
        push    word 0
        call    DrawSprite
.skip:
        add     bx, ENEMY_SIZE
        dec     cx
        jnz     .next
        pop     cx
        pop     bx
        pop     ax
        ret

; ==========================================================================
; TEXT, NUMBERS, HEARTS, CLOCK AND HUD (Module 13)
; ==========================================================================

; --------------------------------------------------------------------------
; DrawGlyph(x, y, bitmap, colour)
;   Purpose : draw one 5 x 7 letter shape: 7 bytes, one per row, bit 4 is the
;             leftmost pixel. Only the set bits are drawn (the rest stays).
;   Inputs  : on the stack, pushed in this order: x, y, address of the 7 bytes,
;             colour. ES = destination segment
;   Outputs : none
;   Changes : none
; --------------------------------------------------------------------------
DrawGlyph:
        push    bp
        mov     bp, sp
        push    ax
        push    bx
        push    cx
        push    dx
        push    si
        ; [bp+4] = colour, [bp+6] = bitmap, [bp+8] = y, [bp+10] = x
        mov     si, [bp+6]
        xor     dx, dx                  ; DX = row 0..6
.row:
        mov     bl, [si]
        xor     cx, cx                  ; CX = column 0..4
.col:
        test    bl, 10h                 ; leftmost pixel = bit 4
        jz      .blank
        mov     ax, [bp+10]
        add     ax, cx
        push    ax
        mov     ax, [bp+8]
        add     ax, dx
        push    ax
        push    word [bp+4]
        call    PutPixel
.blank:
        shl     bl, 1
        inc     cx
        cmp     cx, 5
        jb      .col
        inc     si
        inc     dx
        cmp     dx, 7
        jb      .row
        pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        pop     bp
        ret     8

; --------------------------------------------------------------------------
; DrawDigit(x, y, digit, colour)
;   Purpose : draw one decimal digit 0..9 (5 x 7 pixels).
;   Inputs  : on the stack, pushed in this order: x, y, digit, colour
;             ES = destination segment
;   Outputs : none
;   Changes : none
; --------------------------------------------------------------------------
DrawDigit:
        push    bp
        mov     bp, sp
        push    ax
        push    si
        ; [bp+4] = colour, [bp+6] = digit, [bp+8] = y, [bp+10] = x
        mov     si, [bp+6]
        mov     ax, si
        shl     si, 3
        sub     si, ax                  ; digit * 7 (8 - 1)
        add     si, font_digits
        push    word [bp+10]
        push    word [bp+8]
        push    si
        push    word [bp+4]
        call    DrawGlyph
        pop     si
        pop     ax
        pop     bp
        ret     8

; --------------------------------------------------------------------------
; FindGlyph(char)
;   Purpose : find the 7-byte shape of a character: digits, capital letters
;             A-Z and the signs listed in symbol_chars.
;   Inputs  : on the stack: char (ASCII, low byte)
;   Outputs : AX = address of the 7 shape bytes, or 0 for a space / unknown
;   Changes : AX only
; --------------------------------------------------------------------------
FindGlyph:
        push    bp
        mov     bp, sp
        push    bx
        ; [bp+4] = char
        mov     ax, [bp+4]
        xor     ah, ah
        cmp     al, '0'
        jb      .not_digit
        cmp     al, '9'
        ja      .not_digit
        sub     al, '0'
        mov     bx, ax
        shl     ax, 3
        sub     ax, bx                  ; digit * 7
        add     ax, font_digits
        jmp     short .done
.not_digit:
        cmp     al, 'A'
        jb      .symbol
        cmp     al, 'Z'
        ja      .symbol
        sub     al, 'A'
        mov     bx, ax
        shl     ax, 3
        sub     ax, bx                  ; letter * 7
        add     ax, font_letters
        jmp     short .done
.symbol:
        xor     bx, bx                  ; look the sign up in symbol_chars
.find:
        cmp     al, [symbol_chars + bx]
        je      .found
        inc     bx
        cmp     bx, SYMBOL_COUNT
        jb      .find
        xor     ax, ax                  ; space or unknown: no shape
        jmp     short .done
.found:
        mov     ax, bx
        shl     ax, 3
        sub     ax, bx                  ; index * 7
        add     ax, font_symbols
.done:
        pop     bx
        pop     bp
        ret     2

; --------------------------------------------------------------------------
; DrawChar(x, y, char, colour)
;   Purpose : draw one character (5 x 7 pixels). A space (or any unknown
;             character) draws nothing. Characters are 6 pixels apart.
;   Inputs  : on the stack, pushed in this order: x, y, char (ASCII, low
;             byte), colour. ES = destination segment
;   Outputs : none
;   Changes : none
; --------------------------------------------------------------------------
DrawChar:
        push    bp
        mov     bp, sp
        push    ax
        ; [bp+4] = colour, [bp+6] = char, [bp+8] = y, [bp+10] = x
        push    word [bp+6]
        call    FindGlyph
        or      ax, ax
        jz      .done
        push    word [bp+10]
        push    word [bp+8]
        push    ax
        push    word [bp+4]
        call    DrawGlyph
.done:
        pop     ax
        pop     bp
        ret     8

; --------------------------------------------------------------------------
; DrawText(x, y, text, colour)
;   Purpose : draw a zero-terminated string, 6 pixels per character.
;   Inputs  : on the stack, pushed in this order: x, y, address of the text,
;             colour. ES = destination segment
;   Outputs : none
;   Changes : none
; --------------------------------------------------------------------------
DrawText:
        push    bp
        mov     bp, sp
        push    ax
        push    si
        push    di
        ; [bp+4] = colour, [bp+6] = text, [bp+8] = y, [bp+10] = x
        mov     si, [bp+6]
        mov     di, [bp+10]             ; DI = x of the next character
.next:
        mov     al, [si]
        or      al, al
        jz      .done                   ; the 0 ends the text
        xor     ah, ah
        push    di
        push    word [bp+8]
        push    ax
        push    word [bp+4]
        call    DrawChar
        add     di, 6
        inc     si
        jmp     short .next
.done:
        pop     di
        pop     si
        pop     ax
        pop     bp
        ret     8

; --------------------------------------------------------------------------
; DrawNumber(x, y, value, digits, colour)
;   Purpose : draw an unsigned 16-bit number with a fixed number of digits
;             (zero-padded). The digits come from repeated division by 10:
;             each remainder is PUSHED on the stack (last digit first), then
;             POPPED again, which gives them back in reading order.
;             A number with more digits than asked for shows its low digits.
;   Inputs  : on the stack, pushed in this order: x, y, value, digits (1..5),
;             colour. ES = destination segment
;   Outputs : none
;   Changes : none
; --------------------------------------------------------------------------
DrawNumber:
        push    bp
        mov     bp, sp
        push    ax
        push    cx
        push    dx
        push    si
        ; [bp+4] = colour, [bp+6] = digits, [bp+8] = value, [bp+10] = y, [bp+12] = x
        mov     cx, [bp+6]
        mov     ax, [bp+8]
.divide:
        xor     dx, dx
        div     word [ten]              ; AX = value / 10, DX = last digit
        push    dx                      ; remainders go on the stack
        dec     cx
        jnz     .divide
        mov     cx, [bp+6]
        mov     si, [bp+12]             ; SI = x of the next digit
.draw:
        pop     ax                      ; first digit comes out first
        push    si
        push    word [bp+10]
        push    ax
        push    word [bp+4]
        call    DrawDigit
        add     si, 6
        dec     cx
        jnz     .draw
        pop     si
        pop     dx
        pop     cx
        pop     ax
        pop     bp
        ret     10

; --------------------------------------------------------------------------
; DrawScore(x, y, low, high, colour)
;   Purpose : draw a 32-bit number as six decimal digits (000000..999999).
;             DIV works on 32 bits in two steps (the high word first, then the
;             remainder together with the low word). Remainders are pushed
;             and popped like in DrawNumber.
;   Inputs  : on the stack, pushed in this order: x, y, low word, high word,
;             colour. ES = destination segment
;   Outputs : none
;   Changes : none
; --------------------------------------------------------------------------
DrawScore:
        push    bp
        mov     bp, sp
        push    ax
        push    bx
        push    cx
        push    dx
        push    si
        push    di
        ; [bp+4] = colour, [bp+6] = high, [bp+8] = low, [bp+10] = y, [bp+12] = x
        mov     si, [bp+8]              ; SI = low word (working copy)
        mov     bx, [bp+6]              ; BX = high word (working copy)
        mov     cx, 6
.divide:
        xor     dx, dx
        mov     ax, bx
        div     word [ten]              ; AX = high / 10, DX = remainder
        mov     bx, ax
        mov     ax, si
        div     word [ten]              ; (remainder : low) / 10: DX = digit
        mov     si, ax
        push    dx
        dec     cx
        jnz     .divide
        mov     cx, 6
        mov     di, [bp+12]
.draw:
        pop     ax
        push    di
        push    word [bp+10]
        push    ax
        push    word [bp+4]
        call    DrawDigit
        add     di, 6
        dec     cx
        jnz     .draw
        pop     di
        pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        pop     bp
        ret     10

; --------------------------------------------------------------------------
; DrawGlyphScaled(x, y, bitmap, colour, scale)
;   Purpose : like DrawGlyph but every shape pixel becomes a scale x scale
;             square (big letters for titles).
;   Inputs  : on the stack, pushed in this order: x, y, address of the 7 bytes,
;             colour, scale. ES = destination segment
;   Outputs : none
;   Changes : none
; --------------------------------------------------------------------------
DrawGlyphScaled:
        push    bp
        mov     bp, sp
        push    ax
        push    bx
        push    cx
        push    dx
        push    si
        push    di
        ; [bp+4] = scale, [bp+6] = colour, [bp+8] = bitmap, [bp+10] = y, [bp+12] = x
        mov     si, [bp+8]
        xor     di, di                  ; DI = row 0..6
.row:
        mov     bl, [si]
        xor     cx, cx                  ; CX = column 0..4
.col:
        test    bl, 10h
        jz      .blank
        mov     ax, cx
        mul     word [bp+4]             ; column * scale
        add     ax, [bp+12]
        push    ax                      ; x
        mov     ax, di
        mul     word [bp+4]             ; row * scale
        add     ax, [bp+10]
        push    ax                      ; y
        push    word [bp+4]             ; width
        push    word [bp+4]             ; height
        push    word [bp+6]
        call    FillRect
.blank:
        shl     bl, 1
        inc     cx
        cmp     cx, 5
        jb      .col
        inc     si
        inc     di
        cmp     di, 7
        jb      .row
        pop     di
        pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        pop     bp
        ret     10

; --------------------------------------------------------------------------
; DrawTextScaled(x, y, text, colour, scale)
;   Purpose : draw a zero-terminated string with big letters
;             (6 * scale pixels per character).
;   Inputs  : on the stack, pushed in this order: x, y, address of the text,
;             colour, scale. ES = destination segment
;   Outputs : none
;   Changes : none
; --------------------------------------------------------------------------
DrawTextScaled:
        push    bp
        mov     bp, sp
        push    ax
        push    bx
        push    dx
        push    si
        push    di
        ; [bp+4] = scale, [bp+6] = colour, [bp+8] = text, [bp+10] = y, [bp+12] = x
        mov     ax, [bp+4]
        mov     bx, 6
        mul     bx                      ; AX = 6 * scale
        mov     bx, ax                  ; BX = distance between two characters
        mov     si, [bp+8]
        mov     di, [bp+12]             ; DI = x of the next character
.next:
        mov     al, [si]
        or      al, al
        jz      .done
        xor     ah, ah
        push    ax
        call    FindGlyph
        or      ax, ax
        jz      .skip                   ; a space
        push    di
        push    word [bp+10]
        push    ax
        push    word [bp+6]
        push    word [bp+4]
        call    DrawGlyphScaled
.skip:
        add     di, bx
        inc     si
        jmp     short .next
.done:
        pop     di
        pop     si
        pop     dx
        pop     bx
        pop     ax
        pop     bp
        ret     10

; --------------------------------------------------------------------------
; TextWidth(text, scale)
;   Purpose : width in pixels of a zero-terminated string:
;             characters * 6 * scale - scale (no gap after the last one).
;   Inputs  : on the stack, pushed in this order: address of the text, scale
;   Outputs : AX = width (0 for an empty text)
;   Changes : AX only
; --------------------------------------------------------------------------
TextWidth:
        push    bp
        mov     bp, sp
        push    cx
        push    dx
        push    si
        ; [bp+4] = scale, [bp+6] = text
        mov     si, [bp+6]
        xor     cx, cx                  ; CX = number of characters
.count:
        cmp     byte [si], 0
        je      .counted
        inc     cx
        inc     si
        jmp     short .count
.counted:
        xor     ax, ax
        or      cx, cx
        jz      .done
        mov     ax, cx
        shl     ax, 2
        shl     cx, 1
        add     ax, cx                  ; characters * 6
        mul     word [bp+4]             ; * scale
        sub     ax, [bp+4]
.done:
        pop     si
        pop     dx
        pop     cx
        pop     bp
        ret     4

; --------------------------------------------------------------------------
; DrawTextCentered(y, text, colour, scale)
;   Purpose : draw a string in the middle of the screen (x = (320 - width) / 2).
;   Inputs  : on the stack, pushed in this order: y, address of the text,
;             colour, scale. ES = destination segment
;   Outputs : none
;   Changes : none
; --------------------------------------------------------------------------
DrawTextCentered:
        push    bp
        mov     bp, sp
        push    ax
        push    bx
        ; [bp+4] = scale, [bp+6] = colour, [bp+8] = text, [bp+10] = y
        push    word [bp+8]
        push    word [bp+4]
        call    TextWidth
        mov     bx, SCREEN_W
        sub     bx, ax
        shr     bx, 1                   ; x = (320 - width) / 2
        push    bx
        push    word [bp+10]
        push    word [bp+8]
        push    word [bp+6]
        push    word [bp+4]
        call    DrawTextScaled
        pop     bx
        pop     ax
        pop     bp
        ret     8

; --------------------------------------------------------------------------
; DrawCharScaled(x, y, char, colour, scale)
;   Purpose : one big character (see DrawGlyphScaled). A space draws nothing.
;   Inputs  : on the stack, pushed in this order: x, y, char, colour, scale
;             ES = destination segment
;   Outputs : none
;   Changes : none
; --------------------------------------------------------------------------
DrawCharScaled:
        push    bp
        mov     bp, sp
        push    ax
        ; [bp+4] = scale, [bp+6] = colour, [bp+8] = char, [bp+10] = y, [bp+12] = x
        push    word [bp+8]
        call    FindGlyph
        or      ax, ax
        jz      .done
        push    word [bp+12]
        push    word [bp+10]
        push    ax
        push    word [bp+6]
        push    word [bp+4]
        call    DrawGlyphScaled
.done:
        pop     ax
        pop     bp
        ret     10

; --------------------------------------------------------------------------
; DrawTextShadow(y, text, colour, scale, shadow_colour)
;   Purpose : a centred big text with a shadow: the text is drawn first in the
;             shadow colour, 2 pixels right and down, then in its own colour.
;   Inputs  : on the stack, pushed in this order: y, address of the text,
;             colour, scale, shadow colour. ES = destination segment
;   Outputs : none
;   Changes : none
; --------------------------------------------------------------------------
DrawTextShadow:
        push    bp
        mov     bp, sp
        push    ax
        push    bx
        ; [bp+4] = shadow colour, [bp+6] = scale, [bp+8] = colour, [bp+10] = text, [bp+12] = y
        push    word [bp+10]
        push    word [bp+6]
        call    TextWidth
        mov     bx, SCREEN_W
        sub     bx, ax
        shr     bx, 1                   ; BX = x of the centred text
        add     bx, 2
        push    bx                      ; the shadow
        mov     ax, [bp+12]
        add     ax, 2
        push    ax
        push    word [bp+10]
        push    word [bp+4]
        push    word [bp+6]
        call    DrawTextScaled
        sub     bx, 2
        push    bx                      ; the text itself
        push    word [bp+12]
        push    word [bp+10]
        push    word [bp+8]
        push    word [bp+6]
        call    DrawTextScaled
        pop     bx
        pop     ax
        pop     bp
        ret     10

; --------------------------------------------------------------------------
; DrawBorderRect(x, y, w, h, colour, thickness)
;   Purpose : the outline of a rectangle (four filled strips).
;   Inputs  : on the stack, pushed in this order: x, y, w, h, colour, thickness
;             ES = destination segment
;   Outputs : none
;   Changes : none
; --------------------------------------------------------------------------
DrawBorderRect:
        push    bp
        mov     bp, sp
        push    ax
        ; [bp+4] = thick, [bp+6] = colour, [bp+8] = h, [bp+10] = w, [bp+12] = y, [bp+14] = x
        push    word [bp+14]            ; top
        push    word [bp+12]
        push    word [bp+10]
        push    word [bp+4]
        push    word [bp+6]
        call    FillRect
        push    word [bp+14]            ; bottom
        mov     ax, [bp+12]
        add     ax, [bp+8]
        sub     ax, [bp+4]
        push    ax
        push    word [bp+10]
        push    word [bp+4]
        push    word [bp+6]
        call    FillRect
        push    word [bp+14]            ; left
        push    word [bp+12]
        push    word [bp+4]
        push    word [bp+8]
        push    word [bp+6]
        call    FillRect
        mov     ax, [bp+14]             ; right
        add     ax, [bp+10]
        sub     ax, [bp+4]
        push    ax
        push    word [bp+12]
        push    word [bp+4]
        push    word [bp+8]
        push    word [bp+6]
        call    FillRect
        pop     ax
        pop     bp
        ret     12

; --------------------------------------------------------------------------
; NumToText(value, digits, dest)
;   Purpose : write an unsigned 16-bit number as `digits` ASCII digits
;             (zero-padded) into a text buffer. Remainders of the repeated
;             division by 10 are pushed, then popped in reading order.
;             No terminating 0 is written (the buffer has its own).
;   Inputs  : on the stack, pushed in this order: value, digits (1..5), address
;   Outputs : the buffer
;   Changes : none
; --------------------------------------------------------------------------
NumToText:
        push    bp
        mov     bp, sp
        push    ax
        push    cx
        push    dx
        push    di
        ; [bp+4] = dest, [bp+6] = digits, [bp+8] = value
        mov     cx, [bp+6]
        mov     ax, [bp+8]
.divide:
        xor     dx, dx
        div     word [ten]
        push    dx
        dec     cx
        jnz     .divide
        mov     cx, [bp+6]
        mov     di, [bp+4]
.out:
        pop     ax
        add     al, '0'
        mov     [di], al
        inc     di
        dec     cx
        jnz     .out
        pop     di
        pop     dx
        pop     cx
        pop     ax
        pop     bp
        ret     6

; --------------------------------------------------------------------------
; ScoreToText(low, high, dest)
;   Purpose : the 32-bit score as six ASCII digits in a text buffer.
;   Inputs  : on the stack, pushed in this order: low word, high word, address
;   Outputs : the buffer (no terminating 0 written)
;   Changes : none
; --------------------------------------------------------------------------
ScoreToText:
        push    bp
        mov     bp, sp
        push    ax
        push    bx
        push    cx
        push    dx
        push    si
        push    di
        ; [bp+4] = dest, [bp+6] = high, [bp+8] = low
        mov     si, [bp+8]
        mov     bx, [bp+6]
        mov     cx, 6
.divide:
        xor     dx, dx
        mov     ax, bx
        div     word [ten]
        mov     bx, ax
        mov     ax, si
        div     word [ten]
        mov     si, ax
        push    dx
        dec     cx
        jnz     .divide
        mov     cx, 6
        mov     di, [bp+4]
.out:
        pop     ax
        add     al, '0'
        mov     [di], al
        inc     di
        dec     cx
        jnz     .out
        pop     di
        pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        pop     bp
        ret     6

; --------------------------------------------------------------------------
; DrawHeart(x, y, filled)
;   Purpose : draw a heart of 8 x 7 pixels: a red solid one when filled, a
;             white outline when empty.
;   Inputs  : on the stack, pushed in this order: x, y, filled (1 or 0)
;             ES = destination segment
;   Outputs : none
;   Changes : none
; --------------------------------------------------------------------------
DrawHeart:
        push    bp
        mov     bp, sp
        push    ax
        push    bx
        push    cx
        push    dx
        push    si
        ; [bp+4] = filled, [bp+6] = y, [bp+8] = x
        mov     si, heart_outline
        mov     dx, COL_WHITE
        cmp     word [bp+4], 0
        je      .shape_known
        mov     si, heart_solid
        mov     dx, COL_HERO_RED
.shape_known:
        xor     bx, bx                  ; BX = row 0..6
.row:
        mov     al, [si]
        xor     cx, cx                  ; CX = column 0..7
.col:
        test    al, 80h                 ; leftmost pixel = bit 7
        jz      .blank
        push    ax
        mov     ax, [bp+8]
        add     ax, cx
        push    ax
        mov     ax, [bp+6]
        add     ax, bx
        push    ax
        push    dx
        call    PutPixel
        pop     ax                      ; the row bits we saved before drawing
.blank:
        shl     al, 1
        inc     cx
        cmp     cx, 8
        jb      .col
        inc     si
        inc     bx
        cmp     bx, 7
        jb      .row
        pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        pop     bp
        ret     6

; ==========================================================================
; MODULE 14 : GAME STATES AND SCREENS  (Section 5.12)
; ==========================================================================
; game_state holds the state number; RunState uses it as an index into the
; jump table state_table. Every state handler runs ONE frame of its state.
;   0 TITLE      1 PLAYING     2 PAUSED      3 DYING       4 LIFE LOST
;   5 WIN        6 LEVEL DONE  7 GAME OVER   8 EXIT
; ==========================================================================

; --------------------------------------------------------------------------
; KeyEdges
;   Purpose : for every key: key_edge = 1 only in the frame in which the key
;             went down (held now, not held in the previous frame). So one
;             press of Enter or P is one event, however long it is held.
;   Inputs  : none (reads key_state)
;   Outputs : key_edge, key_prev
;   Changes : none
; --------------------------------------------------------------------------
KeyEdges:
        push    ax
        push    bx
        xor     bx, bx
.next:
        mov     al, [key_state + bx]
        mov     ah, [key_prev + bx]
        mov     [key_prev + bx], al
        not     ah
        and     al, ah                  ; 1 only if held now AND not held before
        mov     [key_edge + bx], al
        inc     bx
        cmp     bx, 128
        jb      .next
        pop     bx
        pop     ax
        ret

; --------------------------------------------------------------------------
; RunState
;   Purpose : call the handler of the current state through the jump table.
;   Inputs  : none (reads game_state)
;   Outputs : whatever the handler does
;   Changes : none
; --------------------------------------------------------------------------
RunState:
        push    bx
        mov     byte [snd_hold], 0      ; (only the pause state holds the sound)
        mov     bl, [game_state]
        xor     bh, bh
        shl     bx, 1                   ; table of words
        call    word [state_table + bx]
        pop     bx
        ret

; --------------------------------------------------------------------------
; ShowFrame
;   Purpose : copy the finished frame buffer to the screen (one block move).
;   Inputs  : none
;   Outputs : none
;   Changes : none
; --------------------------------------------------------------------------
ShowFrame:
        cmp     byte [skip_draw], 0     ; catching up: this step is not drawn
        jne     .done
        cmp     byte [behind], 0        ; running late: copy at once
        jne     .copy
        call    WaitRetrace             ; on time: copy when the screen starts a new picture
.copy:
        push    word [frame_seg]
        call    PresentFrame
.done:
        ret

; --------------------------------------------------------------------------
; WaitRetrace
;   Purpose : wait until the VGA starts its vertical retrace (the beam goes
;             back to the top), so the new frame is copied without a visible
;             tear (thin horizontal lines in moving scenes). It gives up after
;             a few thousand reads, so it can never hang.
;   Inputs  : none
;   Outputs : none
;   Changes : none
; --------------------------------------------------------------------------
WaitRetrace:
        push    ax
        push    cx
        push    dx
        mov     dx, 3DAh                ; VGA input status register
        mov     cx, 0FFFFh
.in_retrace:                            ; first leave a retrace that is already running
        in      al, dx
        test    al, 8
        jz      .out_of_retrace
        loop    .in_retrace
.out_of_retrace:
        mov     cx, 0FFFFh
.wait_start:                            ; then wait for the next one to begin
        in      al, dx
        test    al, 8
        jnz     .done
        loop    .wait_start
.done:
        pop     dx
        pop     cx
        pop     ax
        ret

; --------------------------------------------------------------------------
; NewGame
;   Purpose : everything from scratch: score 0, coins 0, 3 lives, and the
;             level, Mario, enemies and clock reset.
;   Inputs  : none
;   Outputs : none
;   Changes : none
; --------------------------------------------------------------------------
NewGame:
        mov     word [score_lo], 0
        mov     word [score_hi], 0
        mov     byte [coins], 0
        mov     byte [lives], START_LIVES
        call    RestartLevel
        ret

; --------------------------------------------------------------------------
; StateTitle   (TITLE: Up/Down move the highlight, Enter chooses, Esc exits)
; --------------------------------------------------------------------------
StateTitle:
        push    ax
        mov     byte [mus_mode], 0      ; no music on the title screen
        cmp     byte [key_edge + SC_ESC], 0
        jne     .exit
        cmp     byte [key_edge + SC_UP], 0
        je      .not_up
        mov     byte [menu_sel], 0      ; highlight START GAME
.not_up:
        cmp     byte [key_edge + SC_DOWN], 0
        je      .not_down
        mov     byte [menu_sel], 1      ; highlight EXIT
.not_down:
        cmp     byte [key_edge + SC_ENTER], 0
        je      .draw
        cmp     byte [menu_sel], 0
        jne     .exit                   ; Enter on EXIT
        call    NewGame                 ; Enter on START GAME
        mov     byte [game_state], ST_PLAYING
        jmp     short .done
.exit:
        mov     byte [game_state], ST_EXIT
        jmp     short .done
.draw:
        call    DrawTitleScreen
        call    ShowFrame
.done:
        pop     ax
        ret

; --------------------------------------------------------------------------
; StatePlaying   (PLAYING: the frame order of Section 5.13)
;   P pauses (Esc does nothing here, it only works in the pause), death starts
;   the death animation, the flag pole starts the win sequence.
; --------------------------------------------------------------------------
StatePlaying:
        push    ax
        cmp     byte [key_edge + SC_P], 0       ; (Esc does nothing while playing:
        je      .run                            ;  it only works inside the pause)
        mov     ax, [tick_count]
        mov     [pause_tick], ax        ; the clock is frozen from now on
        mov     byte [game_state], ST_PAUSED
        jmp     .done
.run:
        call    HandleTestKeys          ; test keys: R, E, C, T, 1, 2, 3
        call    UpdateHero              ; 3. Mario: speed, gravity, jump, move + collision
        call    UpdateCamera            ; 8. camera (Section 5.3)
        call    UpdateEnemies           ; 4. enemies, shells, mushrooms
        call    ResolveEnemies          ; 5. stomp, kick, hurt, mushroom
        call    ResolveBlocks           ;    bricks and "?" blocks
        call    CollectCoins            ;    free coins
        call    UpdateFx
        call    UpdateClock             ; 6. the level clock
        cmp     byte [death_kind], 0    ; 7. death check (damage, pit, time)
        je      .alive
        call    BeginDying
        jmp     short .render
.alive:
        call    CheckFlagPole           ;    ... and the flag pole (Section 5.11)
.render:
        call    RenderWorld             ; 9. draw everything
        call    ShowFrame               ; 10. copy to the screen
.done:
        pop     ax
        ret

; --------------------------------------------------------------------------
; StatePaused   (PAUSED: nothing moves, the clock is frozen)
;   P resumes, Esc goes to the title. The picture stays visible with PAUSED.
; --------------------------------------------------------------------------
StatePaused:
        push    ax
        push    dx
        mov     byte [snd_hold], 1      ; music and sounds wait while paused
        mov     ax, [tick_count]
        mov     dx, ax
        sub     ax, [pause_tick]        ; ticks that went by while paused ...
        add     [clock_ref], ax         ; ... are added to the clock reference
        mov     [pause_tick], dx
        cmp     byte [key_edge + SC_ESC], 0
        je      .no_esc
        mov     byte [menu_sel], 0
        mov     byte [game_state], ST_TITLE
        jmp     short .done
.no_esc:
        cmp     byte [key_edge + SC_P], 0
        je      .draw
        mov     byte [game_state], ST_PLAYING
        jmp     short .done
.draw:
        call    RenderWorld
        call    DrawPauseOverlay
        call    ShowFrame
.done:
        pop     dx
        pop     ax
        ret

; --------------------------------------------------------------------------
; BeginDying
;   Purpose : Mario died (Section 5.8): enemies, clock and controls are
;             frozen from now on. A hit or the clock gives a small hop first;
;             a pit death just keeps falling.
;   Inputs  : none (reads death_kind: 1 = hit or time, 2 = pit)
;   Outputs : game_state and the hero variables
;   Changes : none
; --------------------------------------------------------------------------
BeginDying:
        push    word 3                  ; the death tune (plays once)
        push    word mus_death
        call    MusicStart
        mov     byte [game_state], ST_DYING
        mov     word [dying_timer], 0
        mov     word [hero_invuln], 0
        mov     byte [hero_on_ground], 0        ; jumping picture
        mov     word [hero_vx], 0
        cmp     byte [death_kind], 2
        je      .done
        mov     word [hero_vy], DEATH_HOP
.done:
        ret

; --------------------------------------------------------------------------
; StateDying   (DYING: the death animation, no collisions)
;   Mario hops up about 48 pixels and falls off the bottom of the screen.
;   Then lives - 1: LIFE LOST when lives are left, otherwise GAME OVER.
; --------------------------------------------------------------------------
StateDying:
        push    ax
        push    dx
        inc     word [dying_timer]
        mov     ax, [hero_vy]
        add     ax, GRAVITY
        cmp     ax, MAX_FALL
        jle     .speed_ok
        mov     ax, MAX_FALL
.speed_ok:
        mov     [hero_vy], ax
        mov     dx, ax
        add     byte [hero_yf], dl      ; fraction first, then the carry
        mov     al, dh
        cbw
        adc     [hero_y], ax            ; no tile collision while dying
        call    RenderWorld
        call    ShowFrame
        cmp     word [dying_timer], DEATH_MAX
        jae     .finished
        cmp     word [dying_timer], DEATH_MIN
        jb      .done
        mov     ax, [hero_y]            ; top of Mario below the screen?
        sub     ax, TILE_SIZE
        cmp     byte [hero_form], 0
        je      .top_known
        sub     ax, TILE_SIZE
.top_known:
        cmp     ax, SCREEN_H
        jl      .done
.finished:
        dec     byte [lives]            ; Lives - 1
        mov     word [life_timer], LIFELOST_TICKS
        mov     byte [game_state], ST_LIFELOST
        cmp     byte [lives], 0
        jne     .done
        mov     byte [game_state], ST_GAMEOVER  ; no lives left
.done:
        pop     dx
        pop     ax
        ret

; --------------------------------------------------------------------------
; StateLifeLost   (LIFE LOST: the "WORLD 1-1  x lives" screen for about 2 s)
;   Then the level is reset (score and coins are kept) and PLAYING starts.
; --------------------------------------------------------------------------
StateLifeLost:
        call    DrawLifeLostScreen
        call    ShowFrame
        dec     word [life_timer]
        jnz     .done
        call    RestartLevel
        mov     byte [game_state], ST_PLAYING
.done:
        ret

; --------------------------------------------------------------------------
; StateGameOver   (GAME OVER: Enter returns to the title)
; --------------------------------------------------------------------------
StateGameOver:
        cmp     byte [key_edge + SC_ENTER], 0
        je      .draw
        mov     byte [menu_sel], 0
        mov     byte [game_state], ST_TITLE
        ret
.draw:
        call    DrawGameOverScreen
        call    ShowFrame
        ret

; --------------------------------------------------------------------------
; IsFlagAt(px, py)
;   Purpose : is the tile at this world pixel part of the flag pole (the pole
;             tile or the pole top with the flag)?
;   Inputs  : on the stack, pushed in this order: px, py
;   Outputs : AX = 1 yes, 0 no
;   Changes : AX only
; --------------------------------------------------------------------------
IsFlagAt:
        push    bp
        mov     bp, sp
        push    word [bp+6]
        push    word [bp+4]
        call    GetTile
        cmp     ax, T_FLAG
        je      .yes
        cmp     ax, T_FLAG_TOP
        je      .yes
        xor     ax, ax
        jmp     short .done
.yes:
        mov     ax, 1
.done:
        pop     bp
        ret     4

; --------------------------------------------------------------------------
; CheckFlagPole   (step 7 of the frame order)
;   Purpose : does Mario's body overlap the flag pole? Looks at three columns
;             across his body and a row every 8 pixels from his feet to his
;             head. If yes, the win sequence starts.
;   Inputs  : none
;   Outputs : game_state and the win variables (through BeginWin)
;   Changes : none
; --------------------------------------------------------------------------
CheckFlagPole:
        push    ax
        push    bx
        push    cx
        mov     bx, [hero_y]
        dec     bx                      ; BX = pixel row tested, from the feet up
        mov     cx, [hero_y]
        sub     cx, TILE_SIZE
        cmp     byte [hero_form], 0
        je      .top_known
        sub     cx, TILE_SIZE           ; CX = top pixel row of his head
.top_known:
.row:
        mov     ax, [hero_x]
        add     ax, HIT_LEFT
        push    ax
        push    bx
        call    IsFlagAt
        or      ax, ax
        jnz     .touched
        mov     ax, [hero_x]
        add     ax, TILE_SIZE / 2
        push    ax
        push    bx
        call    IsFlagAt
        or      ax, ax
        jnz     .touched
        mov     ax, [hero_x]
        add     ax, HIT_RIGHT
        push    ax
        push    bx
        call    IsFlagAt
        or      ax, ax
        jnz     .touched
        cmp     bx, cx
        jle     .done                   ; that was the top row
        sub     bx, 8
        cmp     bx, cx
        jge     .row
        mov     bx, cx                  ; last row: exactly the top of his head
        jmp     short .row
.touched:
        call    BeginWin
.done:
        pop     cx
        pop     bx
        pop     ax
        ret

; --------------------------------------------------------------------------
; BeginWin   (Section 5.11, steps 1 and 2)
;   Purpose : the flag pole was touched: clock and controls are frozen (the
;             WIN state does not read the keys or count the clock), the flag
;             points are added by the map row of Mario's feet
;             (rows 2-3: 5000, 4: 2000, 5: 800, 6-7: 400, 8: 100), and Mario
;             snaps to the pole.
;   Inputs  : none
;   Outputs : score, game_state, hero variables
;   Changes : none
; --------------------------------------------------------------------------
BeginWin:
        push    ax
        push    bx
        mov     ax, [hero_y]
        dec     ax                      ; lowest pixel row of the feet
        shr     ax, 4                   ; map row of his feet
        cmp     ax, 8
        jbe     .row_ok
        mov     ax, 8                   ; (never lower than the base of the pole)
.row_ok:
        shl     ax, 1                   ; word table
        mov     bx, ax
        mov     ax, [flag_points + bx]
        mov     [flag_award], ax
        push    ax
        call    AddScore
        push    word 2                  ; the victory tune (plays once)
        push    word mus_victory
        call    MusicStart
        mov     byte [game_state], ST_WIN
        mov     byte [win_phase], 0     ; 0 = sliding down, 1 = walking away
        mov     word [win_timer], 0
        mov     word [hero_x], FLAG_X   ; snap to the pole
        mov     byte [hero_xf], 0
        mov     byte [hero_yf], 0
        mov     word [hero_vx], 0
        mov     word [hero_vy], 0
        mov     byte [hero_on_ground], 0        ; the jumping picture holds on to the pole
        mov     byte [hero_facing], 0
        mov     word [hero_invuln], 0
        pop     bx
        pop     ax
        ret

; --------------------------------------------------------------------------
; StateWin   (WIN SEQUENCE: slide down the pole, then walk away)
;   Phase 0: Mario slides to the base of the pole (3 pixels per frame, about
;            1 s). Phase 1: he walks right for about 1 s (stepping off the base
;            block and dropping to the ground) and leaves the screen. Nothing
;            else moves, the clock does not run and the keys are not read.
; --------------------------------------------------------------------------
StateWin:
        push    ax
        cmp     byte [win_phase], 0
        jne     .walk
        add     word [hero_y], SLIDE_SPEED
        cmp     word [hero_y], BASE_Y
        jl      .draw
        mov     word [hero_y], BASE_Y   ; the slide ends on top of the base block
        mov     byte [win_phase], 1
        mov     word [win_timer], 0
        mov     byte [hero_on_ground], 1        ; walking picture from now on
        mov     word [hero_vx], 0200h
        jmp     short .draw
.walk:
        add     word [hero_x], 2
        mov     ax, [hero_x]
        add     ax, HIT_LEFT
        cmp     ax, FLAG_X + TILE_SIZE
        jl      .on_block               ; still above the base block
        cmp     word [hero_y], GROUND_Y
        jge     .on_block
        add     word [hero_y], 4        ; off the block: drop to the ground
        cmp     word [hero_y], GROUND_Y
        jle     .on_block
        mov     word [hero_y], GROUND_Y
.on_block:
        inc     word [win_timer]
        cmp     word [win_timer], WIN_WALK_TICKS
        jb      .draw
        call    FinishWin
        jmp     short .done
.draw:
        call    RenderWorld
        call    ShowFrame
.done:
        pop     ax
        ret

; --------------------------------------------------------------------------
; FinishWin   (Section 5.11, step 4)
;   Purpose : the remaining time becomes points (time left x 50), added to
;             the score; then the Level Complete screen is shown.
;   Inputs  : none (reads level_clock)
;   Outputs : score, time_bonus, game_state
;   Changes : none
; --------------------------------------------------------------------------
FinishWin:
        push    ax
        push    bx
        push    dx
        mov     ax, [level_clock]
        mov     bx, 50
        mul     bx                      ; DX:AX = time left x 50 (at most 15000)
        mov     [time_bonus], ax
        push    ax
        call    AddScore
        mov     byte [game_state], ST_LEVELDONE
        pop     dx
        pop     bx
        pop     ax
        ret

; --------------------------------------------------------------------------
; StateLevelDone   (LEVEL COMPLETE: Enter returns to the title)
;   A win gives no extra life. START GAME on the title begins from scratch.
; --------------------------------------------------------------------------
StateLevelDone:
        cmp     byte [key_edge + SC_ENTER], 0
        je      .draw
        mov     byte [menu_sel], 0
        mov     byte [game_state], ST_TITLE
        ret
.draw:
        call    DrawLevelCompleteScreen
        call    ShowFrame
        ret

; --------------------------------------------------------------------------
; StateExit   (EXIT: the main loop sees it and leaves; nothing to do)
; --------------------------------------------------------------------------
StateExit:
        ret

; ==========================================================================
; SCREENS
; ==========================================================================

; --------------------------------------------------------------------------
; DrawBrickBorder
;   Purpose : a frame of brick tiles around the whole screen.
;   Inputs  : ES = destination segment
;   Outputs : none
;   Changes : none
; --------------------------------------------------------------------------
DrawBrickBorder:
        push    ax
        push    bx
        xor     bx, bx
.across:                                ; top and bottom rows
        mov     ax, bx
        shl     ax, 4
        push    ax
        push    word 0
        push    word T_BRICK
        call    DrawTile
        push    ax
        push    word SCREEN_H - TILE_SIZE
        push    word T_BRICK
        call    DrawTile
        inc     bx
        cmp     bx, 20
        jb      .across
        mov     bx, 1
.down:                                  ; left and right columns
        mov     ax, bx
        shl     ax, 4
        push    word 0
        push    ax
        push    word T_BRICK
        call    DrawTile
        push    word SCREEN_W - TILE_SIZE
        push    ax
        push    word T_BRICK
        call    DrawTile
        inc     bx
        cmp     bx, 11
        jbe     .down
        pop     bx
        pop     ax
        ret

; --------------------------------------------------------------------------
; DrawTitleScreen
;   Purpose : the title picture in the frame buffer: brick frame, big title,
;             START GAME / EXIT with the highlight on the chosen one, a small
;             hero and walker on a strip of ground, and the team line.
;   Inputs  : none (reads menu_sel)
;   Outputs : none
;   Changes : ES (set to the frame buffer segment)
; --------------------------------------------------------------------------
DrawTitleScreen:
        push    ax
        push    bx
        mov     ax, [frame_seg]
        mov     es, ax
        push    word COL_SKY
        call    ClearBuffer
        call    DrawBrickBorder

        mov     bx, 1                   ; two rows of ground between the bricks
.ground:
        mov     ax, bx
        shl     ax, 4
        push    ax
        push    word 152
        push    word T_GROUND
        call    DrawTile
        push    ax
        push    word 168
        push    word T_GROUND
        call    DrawTile
        inc     bx
        cmp     bx, 19
        jb      .ground
        push    word 24                 ; the hero and a walker stand on it
        push    word 136
        push    word spr_hero_stand
        push    word 0
        call    DrawSprite
        push    word 280
        push    word 136
        push    word spr_walker_a
        push    word 0
        call    DrawSprite

        push    word 26                 ; the title: a dark shadow, then the red letters
        push    word txt_title
        push    word COL_HERO_RED
        push    word 3
        push    word COL_OUTLINE
        call    DrawTextShadow
        push    word 64
        push    word txt_engine
        push    word COL_WHITE
        push    word 2
        call    DrawTextCentered

        push    word 80                 ; the menu box
        push    word 90
        push    word 160
        push    word 52
        push    word COL_BLACK
        call    FillRect
        push    word 80
        push    word 90
        push    word 160
        push    word 52
        push    word COL_WHITE
        push    word 2
        call    DrawBorderRect
        mov     ax, COL_HUD_YELLOW      ; START GAME: highlighted when menu_sel = 0
        cmp     byte [menu_sel], 0
        je      .start_colour
        mov     ax, COL_WHITE
.start_colour:
        push    word 100
        push    word 100
        push    word txt_start
        push    ax
        push    word 2
        call    DrawTextScaled
        mov     ax, COL_HUD_YELLOW
        cmp     byte [menu_sel], 1
        je      .exit_colour
        mov     ax, COL_WHITE
.exit_colour:
        push    word 100
        push    word 120
        push    word txt_exit
        push    ax
        push    word 2
        call    DrawTextScaled
        mov     bx, 100                 ; the arrow beside the highlighted item
        cmp     byte [menu_sel], 0
        je      .arrow_y
        mov     bx, 120
.arrow_y:
        push    word 88
        push    bx
        push    word '>'
        push    word COL_HUD_YELLOW
        push    word 2
        call    DrawCharScaled
        push    word 150                ; sound state under the menu box
        call    DrawSoundLine
        push    word 172                ; team line on the ground
        push    word txt_team
        push    word COL_WHITE
        push    word 1
        call    DrawTextCentered
        pop     bx
        pop     ax
        ret


; --------------------------------------------------------------------------
; DrawPauseOverlay
;   Purpose : a box with PAUSED over the picture that is already in the frame
;             buffer (the game stays visible around it).
;   Inputs  : ES = frame buffer segment
;   Outputs : none
;   Changes : none
; --------------------------------------------------------------------------
DrawPauseOverlay:
        push    word 80
        push    word 76
        push    word 160
        push    word 68
        push    word COL_BLACK
        call    FillRect
        push    word 80
        push    word 76
        push    word 160
        push    word 68
        push    word COL_WHITE
        push    word 2
        call    DrawBorderRect
        push    word 88
        push    word txt_paused
        push    word COL_HUD_YELLOW
        push    word 3
        call    DrawTextCentered
        push    word 112
        push    word txt_resume
        push    word COL_WHITE
        push    word 1
        call    DrawTextCentered
        push    word 122
        push    word txt_esc_title
        push    word COL_WHITE
        push    word 1
        call    DrawTextCentered
        push    word 132
        call    DrawSoundLine
        ret

; --------------------------------------------------------------------------
; DrawLifeLostScreen
;   Purpose : black screen: WORLD 1-1, the hero icon and "x" lives left.
;   Inputs  : none
;   Outputs : none
;   Changes : ES (set to the frame buffer segment)
; --------------------------------------------------------------------------
DrawLifeLostScreen:
        push    ax
        mov     ax, [frame_seg]
        mov     es, ax
        push    word COL_BLACK
        call    ClearBuffer
        push    word 64
        push    word txt_level_name
        push    word COL_HUD_YELLOW
        push    word 3
        call    DrawTextCentered
        xor     ax, ax
        mov     al, [lives]
        push    ax
        push    word 2
        push    word ll_lives + 2       ; the two digits after "x "
        call    NumToText
        push    word 124                ; hero icon and the text beside it
        push    word 100
        push    word spr_hero_stand
        push    word 0
        call    DrawSprite
        push    word 148
        push    word 102
        push    word ll_lives
        push    word COL_WHITE
        push    word 2
        call    DrawTextScaled
        push    word 150
        push    word txt_get_ready
        push    word COL_KOOPA
        push    word 1
        call    DrawTextCentered
        pop     ax
        ret

; --------------------------------------------------------------------------
; DrawGameOverScreen
;   Purpose : black screen with a red frame: GAME OVER, final score, coins,
;             time and "press Enter".
;   Inputs  : none (reads score, coins, level_clock)
;   Outputs : none
;   Changes : ES (set to the frame buffer segment)
; --------------------------------------------------------------------------
DrawGameOverScreen:
        push    ax
        mov     ax, [frame_seg]
        mov     es, ax
        push    word COL_BLACK
        call    ClearBuffer
        push    word 32
        push    word 24
        push    word 256
        push    word 152
        push    word COL_HERO_RED
        push    word 3
        call    DrawBorderRect
        push    word 56
        push    word txt_gameover
        push    word COL_HERO_RED
        push    word 2
        call    DrawTextCentered
        push    word [score_lo]
        push    word [score_hi]
        push    word go_score + 13      ; six digits after "FINAL SCORE: "
        call    ScoreToText
        push    word 92
        push    word go_score
        push    word COL_WHITE
        push    word 1
        call    DrawTextCentered
        xor     ax, ax
        mov     al, [coins]
        push    ax
        push    word 2
        push    word go_line2 + 7
        call    NumToText
        push    word [level_clock]
        push    word 3
        push    word go_line2 + 19
        call    NumToText
        push    word 110
        push    word go_line2
        push    word COL_HUD_YELLOW
        push    word 1
        call    DrawTextCentered
        push    word 140
        push    word txt_press_enter
        push    word COL_KOOPA
        push    word 1
        call    DrawTextCentered
        pop     ax
        ret

; --------------------------------------------------------------------------
; DrawLevelCompleteScreen
;   Purpose : black screen with a green frame: LEVEL COMPLETE, the score
;             (already including the time bonus), the coins, the flag points
;             and the time bonus "time left x 50 = points".
;   Inputs  : none
;   Outputs : none
;   Changes : ES (set to the frame buffer segment)
; --------------------------------------------------------------------------
DrawLevelCompleteScreen:
        push    ax
        mov     ax, [frame_seg]
        mov     es, ax
        push    word COL_BLACK
        call    ClearBuffer
        push    word 32
        push    word 24
        push    word 256
        push    word 152
        push    word COL_GRASS
        push    word 3
        call    DrawBorderRect
        push    word 44
        push    word txt_level_done
        push    word COL_HUD_YELLOW
        push    word 2
        call    DrawTextCentered
        push    word [score_lo]
        push    word [score_hi]
        push    word lc_score + 7       ; six digits after "SCORE: "
        call    ScoreToText
        push    word 76
        push    word lc_score
        push    word COL_WHITE
        push    word 1
        call    DrawTextCentered
        xor     ax, ax
        mov     al, [coins]
        push    ax
        push    word 2
        push    word lc_coins + 7
        call    NumToText
        push    word 90
        push    word lc_coins
        push    word COL_WHITE
        push    word 1
        call    DrawTextCentered
        push    word [flag_award]
        push    word 5
        push    word lc_flag + 12
        call    NumToText
        push    word 104
        push    word lc_flag
        push    word COL_HUD_YELLOW
        push    word 1
        call    DrawTextCentered
        push    word [level_clock]
        push    word 3
        push    word lc_time + 11
        call    NumToText
        push    word [time_bonus]
        push    word 5
        push    word lc_time + 22
        call    NumToText
        push    word 118
        push    word lc_time
        push    word COL_HUD_YELLOW
        push    word 1
        call    DrawTextCentered
        push    word 146
        push    word txt_press_enter
        push    word COL_KOOPA
        push    word 1
        call    DrawTextCentered
        pop     ax
        ret

; --------------------------------------------------------------------------
; ResetClock
;   Purpose : the level clock starts again at 300 seconds. The seconds are
;             counted from the timer tick counter: clock_ref is the tick at
;             which the current second began.
;   Inputs  : none
;   Outputs : level_clock, clock_ref
;   Changes : none
; --------------------------------------------------------------------------
ResetClock:
        push    ax
        mov     word [level_clock], LEVEL_TIME
        mov     ax, [tick_count]
        mov     [clock_ref], ax
        pop     ax
        ret

; --------------------------------------------------------------------------
; UpdateClock  (Section 5.10, step 6 of the frame order)
;   Purpose : once per real second (30 timer ticks, however many frames we
;             managed to draw) the clock goes down by one. No delay loops.
;             When it reaches 0, Mario dies whatever his health (Stage 12:
;             the level simply restarts; the real death sequence is Module 15).
;   Inputs  : none (reads tick_count)
;   Outputs : level_clock, clock_ref
;   Changes : none
; --------------------------------------------------------------------------
UpdateClock:
        push    ax
.again:
        mov     ax, [tick_count]
        sub     ax, [clock_ref]         ; ticks since the current second began
        cmp     ax, TICKS_PER_SEC
        jb      .done
        add     word [clock_ref], TICKS_PER_SEC
        cmp     word [level_clock], 0
        je      .done
        dec     word [level_clock]
        jnz     .again
        cmp     byte [death_kind], 0
        jne     .done
        mov     byte [death_kind], 1    ; time is up: Mario dies whatever his health
.done:
        pop     ax
        ret

; --------------------------------------------------------------------------
; DrawHudStrip  (Section 5.14)  - draws the HUD; DrawHud (below) caches it
;   Purpose : the top 16-pixel strip: SCORE (6 digits), COINS (x + 2 digits),
;             WORLD 1-1, TIME (3 digits), LIVES (x + number) and HEALTH (one red
;             heart per life left: 3, then 2, then 1).
;             Labels are on the upper line, values on the lower line.
;   Inputs  : ES = destination segment
;   Outputs : none
;   Changes : none
; --------------------------------------------------------------------------
DrawHudStrip:
        push    ax
        push    bx
        push    cx
        push    word 0                  ; dark strip behind the text
        push    word 0
        push    word SCREEN_W
        push    word HUD_HEIGHT
        push    word COL_BLACK
        call    FillRect

        push    word 8                  ; ---- labels (yellow, y = 1)
        push    word 1
        push    word txt_score
        push    word COL_HUD_YELLOW
        call    DrawText
        push    word 76
        push    word 1
        push    word txt_coins
        push    word COL_HUD_YELLOW
        call    DrawText
        push    word 124
        push    word 1
        push    word txt_world
        push    word COL_HUD_YELLOW
        call    DrawText
        push    word 172
        push    word 1
        push    word txt_time
        push    word COL_HUD_YELLOW
        call    DrawText
        push    word 216
        push    word 1
        push    word txt_lives
        push    word COL_HUD_YELLOW
        call    DrawText
        push    word 272
        push    word 1
        push    word txt_health
        push    word COL_HUD_YELLOW
        call    DrawText

        push    word 8                  ; ---- values (white, y = 9)
        push    word 9
        push    word [score_lo]
        push    word [score_hi]
        push    word COL_WHITE
        call    DrawScore
        push    word 76
        push    word 9
        push    word 'x'
        push    word COL_WHITE
        call    DrawChar
        xor     ax, ax
        mov     al, [coins]
        push    word 82
        push    word 9
        push    ax
        push    word 2
        push    word COL_WHITE
        call    DrawNumber
        push    word 124
        push    word 9
        push    word txt_level
        push    word COL_WHITE
        call    DrawText
        push    word 172
        push    word 9
        push    word [level_clock]
        push    word 3
        push    word COL_WHITE
        call    DrawNumber
        ; ---- LIVES: "x3", "x2", "x1" ... (one digit below 10, two digits from 10) ----
        xor     ax, ax
        mov     al, [lives]
        push    word 216
        push    word 9
        push    word 'x'
        push    word COL_WHITE
        call    DrawChar
        mov     bx, 1                   ; BX = number of digits
        cmp     ax, 10
        jb      .one_digit
        mov     bx, 2
.one_digit:
        push    word 222
        push    word 9
        push    ax
        push    bx
        push    word COL_WHITE
        call    DrawNumber
        ; ---- HEALTH: one red heart for every life left (3, 2, 1; never an empty heart) ----
        xor     cx, cx
        mov     cl, [lives]
        cmp     cx, 4
        jbe     .hearts_ok
        mov     cx, 4                   ; (at most 4 hearts fit in the strip)
.hearts_ok:
        mov     bx, 272                 ; BX = x of the next heart
        or      cx, cx
        jz      .health_done
.health_heart:
        push    bx
        push    word 9
        push    word 1                  ; filled
        call    DrawHeart
        add     bx, 10
        dec     cx
        jnz     .health_heart
.health_done:
        pop     cx
        pop     bx
        pop     ax
        ret

; --------------------------------------------------------------------------
; DrawHud
;   Purpose : put the HUD strip (top 16 rows) into the frame buffer. Drawing
;             the text pixel by pixel every frame is slow, so the strip is
;             drawn into hud_cache only when SCORE, COINS, TIME or LIVES
;             changed, and every frame it is copied with one block move.
;   Inputs  : ES = destination segment
;   Outputs : none
;   Changes : none
; --------------------------------------------------------------------------
DrawHud:
        pushf
        push    ax
        push    cx
        push    si
        push    di
        push    es                      ; (the real destination)

        cmp     byte [hs_valid], 0
        je      .rebuild
        mov     ax, [score_lo]
        cmp     ax, [hs_score_lo]
        jne     .rebuild
        mov     ax, [score_hi]
        cmp     ax, [hs_score_hi]
        jne     .rebuild
        mov     ax, [level_clock]
        cmp     ax, [hs_clock]
        jne     .rebuild
        mov     al, [coins]
        mov     ah, [lives]
        cmp     ax, [hs_coins_lives]
        je      .copy
.rebuild:
        mov     ax, [score_lo]
        mov     [hs_score_lo], ax
        mov     ax, [score_hi]
        mov     [hs_score_hi], ax
        mov     ax, [level_clock]
        mov     [hs_clock], ax
        mov     al, [coins]
        mov     ah, [lives]
        mov     [hs_coins_lives], ax
        mov     byte [hs_valid], 1
        mov     ax, hud_cache
        shr     ax, 4                   ; hud_cache is aligned to 16 bytes
        mov     cx, ds
        add     ax, cx
        mov     es, ax                  ; ES:0 = the first byte of hud_cache
        call    DrawHudStrip
.copy:
        pop     es                      ; the real destination again
        push    es
        mov     si, hud_cache
        xor     di, di
        mov     cx, SCREEN_W * HUD_HEIGHT / 2
        cld
        rep movsw                       ; one block move for the whole strip

        pop     es
        pop     di
        pop     si
        pop     cx
        pop     ax
        popf
        ret

; ==========================================================================
; MODULE 16 : SOUND (PC speaker)
; ==========================================================================
; The PC speaker is driven by channel 2 of the timer chip. To play a note we
; give that channel a divisor (1193182 / frequency) and switch the speaker on
; (bits 0 and 1 of port 61h). It needs no extra interrupt: SoundTick runs
; inside the existing 30 Hz timer interrupt, so the keyboard handler and the
; game timing are not touched. A tune is a list of notes: a word (the divisor,
; 0 = rest) and a byte (length in ticks), ended by the word 0FFFFh.
; One music voice and one sound-effect voice run together; while an effect
; plays it takes over the speaker and the music goes on silently underneath.

; --------------------------------------------------------------------------
; SetTone
;   Purpose : make the speaker play a divisor (0 = speaker off). Does nothing
;             when it already plays that note.
;   Inputs  : AX = divisor
;   Outputs : snd_last
;   Changes : AX
;   Notes   : only used by the timer interrupt (interrupts are off there).
; --------------------------------------------------------------------------
SetTone:
        cmp     ax, [snd_last]
        je      .done
        mov     [snd_last], ax
        or      ax, ax
        jz      .silent
        push    bx
        mov     bx, ax
        mov     al, 0B6h                ; channel 2, low then high byte, square wave
        out     43h, al
        mov     al, bl
        out     42h, al
        mov     al, bh
        out     42h, al
        in      al, 61h
        or      al, 3                   ; speaker on
        out     61h, al
        pop     bx
        jmp     short .done
.silent:
        in      al, 61h
        and     al, 0FCh                ; speaker off
        out     61h, al
.done:
        ret

; --------------------------------------------------------------------------
; SoundTick   (called by TimerISR, 30 times per second)
;   Purpose : move both voices on by one tick and set the speaker.
;   Inputs  : DS = our segment
;   Outputs : the speaker, the sound variables
;   Changes : AX (the interrupt handler saved it); BX, DX, SI are saved here
; --------------------------------------------------------------------------
SoundTick:
        push    bx
        push    dx
        push    si

        cmp     byte [snd_on], 0
        je      .quiet
        cmp     byte [snd_hold], 0
        jne     .quiet

        ; ---- music voice ----
        cmp     byte [mus_mode], 0
        jne     .music
        mov     word [mus_cur], 0
        jmp     short .effects
.music:
        cmp     byte [mus_timer], 0
        je      .mus_load
        dec     byte [mus_timer]
        jnz     .effects                ; the note goes on
.mus_load:
        mov     si, [mus_ptr]
        mov     ax, [si]
        cmp     ax, 0FFFFh              ; end of the tune?
        jne     .mus_note
        cmp     byte [mus_mode], 1
        jne     .mus_stop               ; victory / death tune: stop
        mov     si, [mus_start]         ; background music: again from the start
        mov     ax, [si]
.mus_note:
        mov     dl, [si + 2]
        mov     [mus_timer], dl
        add     si, 3
        mov     [mus_ptr], si
        mov     [mus_cur], ax
        jmp     short .effects
.mus_stop:
        mov     byte [mus_mode], 0
        mov     word [mus_cur], 0

        ; ---- sound-effect voice ----
.effects:
        mov     si, [sfx_ptr]
        or      si, si
        jz      .output                 ; no effect playing
        cmp     byte [sfx_timer], 0
        je      .sfx_load
        dec     byte [sfx_timer]
        jnz     .output
.sfx_load:
        mov     ax, [si]
        cmp     ax, 0FFFFh
        jne     .sfx_note
        mov     word [sfx_ptr], 0       ; the effect is over
        mov     word [sfx_cur], 0
        mov     byte [sfx_prio], 0
        jmp     short .output
.sfx_note:
        mov     dl, [si + 2]
        mov     [sfx_timer], dl
        add     si, 3
        mov     [sfx_ptr], si
        mov     [sfx_cur], ax

        ; ---- what does the speaker play now? ----
.output:
        mov     ax, [mus_cur]
        cmp     word [sfx_ptr], 0
        je      .play
        mov     ax, [sfx_cur]           ; an effect is playing: it wins
.play:
        call    SetTone
        jmp     short .done
.quiet:
        xor     ax, ax
        call    SetTone                 ; sound off or paused: speaker off
.done:
        pop     si
        pop     dx
        pop     bx
        ret

; --------------------------------------------------------------------------
; PlaySfx(table, priority)
;   Purpose : start a sound effect. A new effect replaces the one playing only
;             when its priority is the same or higher (stomp 3, coin and
;             power-up 2, jump 1).
;   Inputs  : on the stack, pushed in this order: table, priority
;   Outputs : sfx variables
;   Changes : none
; --------------------------------------------------------------------------
PlaySfx:
        push    bp
        mov     bp, sp
        push    ax
        pushf
        ; [bp+4] = priority, [bp+6] = table
        cmp     byte [snd_on], 0
        je      .done
        cli                             ; the timer interrupt must not see half of the change
        cmp     word [sfx_ptr], 0
        je      .start
        mov     al, [bp+4]
        cmp     al, [sfx_prio]
        jb      .done                   ; a more important effect is playing
.start:
        mov     ax, [bp+6]
        mov     [sfx_ptr], ax
        mov     byte [sfx_timer], 0
        mov     al, [bp+4]
        mov     [sfx_prio], al
.done:
        popf
        pop     ax
        pop     bp
        ret     4

; --------------------------------------------------------------------------
; MusicStart(table, mode)
;   Purpose : start a tune. Mode 1 = background (loops), 2 and 3 = victory and
;             death tune (play once and stop). The one-shot tunes also cut off
;             any sound effect that is playing.
;   Inputs  : on the stack, pushed in this order: mode, table
;             (push word mode / push word table)
;   Outputs : mus variables
;   Changes : none
; --------------------------------------------------------------------------
MusicStart:
        push    bp
        mov     bp, sp
        push    ax
        pushf
        ; [bp+4] = table, [bp+6] = mode
        cli
        mov     ax, [bp+4]
        mov     [mus_start], ax
        mov     [mus_ptr], ax
        mov     byte [mus_timer], 0
        mov     word [mus_cur], 0
        mov     al, [bp+6]
        mov     [mus_mode], al
        cmp     al, 1
        je      .done
        mov     word [sfx_ptr], 0       ; victory / death: no effects on top
        mov     word [sfx_cur], 0
        mov     byte [sfx_prio], 0
.done:
        popf
        pop     ax
        pop     bp
        ret     4

; --------------------------------------------------------------------------
; HandleSoundKey
;   Purpose : M switches the sound on and off (checked every step, in every
;             state). A message "SOUND ON / OFF" is shown for a moment.
;   Inputs  : none (reads key_edge)
;   Outputs : snd_on, snd_msg
;   Changes : none
; --------------------------------------------------------------------------
HandleSoundKey:
        cmp     byte [key_edge + SC_M], 0
        je      .done
        xor     byte [snd_on], 1
        mov     byte [snd_msg], 45      ; about 1.5 seconds
        cmp     byte [snd_on], 0
        jne     .done
        pushf                           ; sound is now off: stop any note at once
        cli
        mov     word [sfx_ptr], 0
        mov     word [sfx_cur], 0
        mov     byte [sfx_prio], 0
        push    ax
        xor     ax, ax
        call    SetTone
        pop     ax
        popf
.done:
        ret

; --------------------------------------------------------------------------
; DrawSoundLine(y)
;   Purpose : a small line "SOUND: ON - PRESS M" or "SOUND: OFF - PRESS M",
;             centred, for the title screen and the pause box.
;   Inputs  : on the stack: y.   ES = destination segment
;   Outputs : none
;   Changes : none
; --------------------------------------------------------------------------
DrawSoundLine:
        push    bp
        mov     bp, sp
        push    ax
        mov     ax, txt_snd_on
        cmp     byte [snd_on], 0
        jne     .text_ok
        mov     ax, txt_snd_off
.text_ok:
        push    word [bp+4]
        push    ax
        push    word COL_WHITE
        push    word 1
        call    DrawTextCentered
        pop     ax
        pop     bp
        ret     2


; ==========================================================================
; WORLD DRAWING
; ==========================================================================

; --------------------------------------------------------------------------
; RenderWorld
;   Purpose : draw the whole game picture into the frame buffer: sky, level
;             (scrolled by camera_x), coin effects, enemies, Mario and the HUD.
;             It does not copy to the screen (ShowFrame does), so a screen
;             such as PAUSED can still draw on top first.
;   Inputs  : none
;   Outputs : none
;   Changes : ES (set to the frame buffer segment)
; --------------------------------------------------------------------------
RenderWorld:
        cmp     byte [skip_draw], 0     ; catching up: nothing to draw this step
        jne     .skipped
        push    ax
        push    bx
        push    cx
        push    dx
        push    si

        mov     ax, [frame_seg]
        mov     es, ax
        push    word COL_SKY
        call    ClearBuffer

        call    DrawEmerging            ; a rising mushroom is drawn first: the block hides it
        push    word [camera_x]         ; the real level, scrolled
        call    DrawMap
        call    DrawFx
        call    DrawEnemies

        ; ---- which picture? 0 = stand, 1 = run, 2 = jump ----
        xor     dx, dx
        cmp     byte [hero_on_ground], 0
        jne     .on_ground
        mov     dx, 2
        jmp     short .pose_known
.on_ground:
        cmp     word [hero_vx], 0
        je      .pose_known
        mov     dx, 1
.pose_known:
        mov     bl, [hero_form]         ; table index = form * 3 + pose
        xor     bh, bh
        mov     ax, bx
        shl     bx, 1
        add     bx, ax                  ; form * 3
        add     bx, dx
        shl     bx, 1                   ; words
        mov     si, [hero_pose_table + bx]      ; SI = bitmap address

        mov     ax, [hero_y]            ; top of the sprite = feet - height
        sub     ax, 16
        cmp     byte [hero_form], 0
        je      .height_known
        sub     ax, 16                  ; Super is 32 tall
.height_known:
        mov     bx, [hero_x]
        sub     bx, [camera_x]          ; screen x = world x - camera x

        xor     cx, cx                  ; flags
        cmp     byte [hero_facing], 0
        je      .facing_known
        or      cx, FLAG_MIRROR
.facing_known:
        cmp     byte [hero_form], 0
        je      .flags_known
        or      cx, FLAG_TALL
.flags_known:
        test    word [hero_invuln], 0FFFFh
        jz      .draw_hero
        test    byte [tick_count], 1    ; invulnerable: only every other frame
        jnz     .hero_done
.draw_hero:
        push    bx
        push    ax
        push    si
        push    cx
        call    DrawSprite
.hero_done:

        call    DrawHud                 ; the HUD strip on top of everything
        cmp     byte [snd_msg], 0       ; "SOUND ON" / "SOUND OFF" for about 1.5 seconds
        je      .no_snd_msg
        dec     byte [snd_msg]
        mov     ax, txt_sound_on
        cmp     byte [snd_on], 0
        jne     .snd_text
        mov     ax, txt_sound_off
.snd_text:
        push    word 20
        push    ax
        push    word COL_WHITE
        push    word 1
        call    DrawTextCentered
.no_snd_msg:

        pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret
.skipped:                              ; (a step that is not drawn: only ES is set as promised)
        push    ax
        mov     ax, [frame_seg]
        mov     es, ax
        pop     ax
        ret

; ==========================================================================
; DATA  (grouped by purpose)
; ==========================================================================

; ---- Palette: 16 colours, red/green/blue each 0..63 (VGA DAC is 6-bit) ----
palette_table:
        db  0,  0,  0           ; 0  black / transparent
        db 21, 35, 63           ; 1  sky blue
        db  8, 44,  4           ; 2  grass green
        db 44, 24,  8           ; 3  dirt brown
        db 50, 20,  8           ; 4  brick orange-red
        db  0, 50, 12           ; 5  pipe green
        db 56,  8,  8           ; 6  hero red
        db 63, 46, 32           ; 7  skin
        db 38, 22,  6           ; 8  goomba brown
        db 63, 63, 63           ; 9  white
        db 63, 58, 10           ; 10 HUD yellow
        db 63, 50,  0           ; 11 coin gold
        db 16,  8,  2           ; 12 dark outline
        db 50, 40, 24           ; 13 stair tan
        db  8, 16, 56           ; 14 hero blue
        db 18, 56, 18           ; 15 koopa green
        db 56,  8,  8           ; 16 red (second picture of the blinking ? blocks)

; ---- Keyboard: one byte per scan code, 1 = held (Module 7) ----
key_state       times 128 db 0
old_int09_off   dw 0            ; the original keyboard handler, saved
old_int09_seg   dw 0

; ---- Timer (Module 8) ----
old_int08_off   dw 0            ; the original timer handler, saved
old_int08_seg   dw 0            ; (offset must come right before segment)
tick_count      dw 0            ; frame ticks since the program started
last_tick       dw 0            ; the tick of the last game step (main loop)
steps_left      dw 0            ; game steps still to run for the ticks that passed
behind          db 0            ; 1 = the game is running behind the timer
hs_valid        db 0            ; 1 = hud_cache holds a finished HUD strip
hs_score_lo     dw 0            ; what the cached HUD strip shows ...
hs_score_hi     dw 0
hs_clock        dw 0
hs_coins_lives  dw 0            ; (coins in the low byte, lives in the high byte)
                align 16
hud_cache       times SCREEN_W * HUD_HEIGHT db 0       ; the HUD strip, 320 x 16 pixels
skip_draw       db 0            ; 1 = run this step without drawing (catching up)
tick_in_second  db 0            ; 0..29, counts ticks inside the current second
seconds_count   dw 0            ; whole real seconds since the program started
bios_acc        dw 0            ; decides when to pass a tick to the BIOS

; ---- Tile bitmaps: 64 tiles, 16 x 16 bytes each (one colour index per pixel) ----
; Tile number * 256 = offset of that tile inside tile_gfx.
; Tiles 0-13 are the tiles of the manual (+ our flag pole top). Tiles 14 and up are scenery
; (clouds, hills, bushes, castle): they are drawn but have no collision (IsSolid is false).
Q_ORANGE        equ 63          ; the second picture of the blinking ? blocks
tile_gfx:
        ; tile 0: Sky
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        ; tile 1: Ground
        db  2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2
        db  2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2
        db  2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2
        db  2, 3, 2, 2, 3, 2, 2, 3, 2, 2, 3, 2, 2, 3, 2, 2
        db  3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3
        db  3, 3, 3, 3, 3, 3, 3, 3, 3,12, 3, 3, 3, 3, 3, 3
        db  3, 3, 3, 3,12, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3
        db  3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3
        db  3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3,12, 3, 3, 3, 3
        db  3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3
        db  3, 3,12, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3
        db  3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3,12, 3
        db  3, 3, 3, 3, 3, 3, 3,12, 3, 3, 3, 3, 3, 3, 3, 3
        db  3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3
        db  3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3
        db  3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3
        ; tile 2: Brick
        db  4, 4, 4, 4, 4, 4, 4,12, 4, 4, 4, 4, 4, 4, 4,12
        db  4, 4, 4, 4, 4, 4, 4,12, 4, 4, 4, 4, 4, 4, 4,12
        db  4, 4, 4, 4, 4, 4, 4,12, 4, 4, 4, 4, 4, 4, 4,12
        db 12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12
        db  4, 4, 4,12, 4, 4, 4, 4, 4, 4, 4,12, 4, 4, 4, 4
        db  4, 4, 4,12, 4, 4, 4, 4, 4, 4, 4,12, 4, 4, 4, 4
        db  4, 4, 4,12, 4, 4, 4, 4, 4, 4, 4,12, 4, 4, 4, 4
        db 12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12
        db  4, 4, 4, 4, 4, 4, 4,12, 4, 4, 4, 4, 4, 4, 4,12
        db  4, 4, 4, 4, 4, 4, 4,12, 4, 4, 4, 4, 4, 4, 4,12
        db  4, 4, 4, 4, 4, 4, 4,12, 4, 4, 4, 4, 4, 4, 4,12
        db 12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12
        db  4, 4, 4,12, 4, 4, 4, 4, 4, 4, 4,12, 4, 4, 4, 4
        db  4, 4, 4,12, 4, 4, 4, 4, 4, 4, 4,12, 4, 4, 4, 4
        db  4, 4, 4,12, 4, 4, 4, 4, 4, 4, 4,12, 4, 4, 4, 4
        db 12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12
        ; tile 3: ? block (coin)
        db 12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12
        db 12,10,10,10,10,10,10,10,10,10,10,10,10,10,10,12
        db 12,10,12,11,11,11,11,11,11,11,11,11,11,12,11,12
        db 12,10,11,11,11,11,11,11,11,11,11,11,11,11,11,12
        db 12,10,11,11,11,11, 9, 9, 9, 9,11,11,11,11,11,12
        db 12,10,11,11,11, 9, 9,11,11, 9, 9,11,11,11,11,12
        db 12,10,11,11,11,11,11,11,11, 9, 9,11,11,11,11,12
        db 12,10,11,11,11,11,11,11, 9, 9,11,11,11,11,11,12
        db 12,10,11,11,11,11,11, 9, 9,11,11,11,11,11,11,12
        db 12,10,11,11,11,11,11, 9, 9,11,11,11,11,11,11,12
        db 12,10,11,11,11,11,11,11,11,11,11,11,11,11,11,12
        db 12,10,11,11,11,11,11, 9, 9,11,11,11,11,11,11,12
        db 12,10,11,11,11,11,11,11,11,11,11,11,11,11,11,12
        db 12,10,12,11,11,11,11,11,11,11,11,11,11,12,11,12
        db 12,10,11,11,11,11,11,11,11,11,11,11,11,11,11,12
        db 12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12
        ; tile 4: ? block (mushroom)
        db 12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12
        db 12,10,10,10,10,10,10,10,10,10,10,10,10,10,10,12
        db 12,10,12,11,11,11,11,11,11,11,11,11,11,12,11,12
        db 12,10,11,11,11,11,11,11,11,11,11,11,11,11,11,12
        db 12,10,11,11,11,11, 9, 9, 9, 9,11,11,11,11,11,12
        db 12,10,11,11,11, 9, 9,11,11, 9, 9,11,11,11,11,12
        db 12,10,11,11,11,11,11,11,11, 9, 9,11,11,11,11,12
        db 12,10,11,11,11,11,11,11, 9, 9,11,11,11,11,11,12
        db 12,10,11,11,11,11,11, 9, 9,11,11,11,11,11,11,12
        db 12,10,11,11,11,11,11, 9, 9,11,11,11,11,11,11,12
        db 12,10,11,11,11,11,11,11,11,11,11,11,11,11,11,12
        db 12,10,11,11,11,11,11, 9, 9,11,11,11,11,11,11,12
        db 12,10,11,11,11,11,11,11,11,11,11,11,11,11,11,12
        db 12,10,12,11,11,11,11,11,11,11,11,11,11,12,11,12
        db 12,10,11,11,11,11,11,11,11,11,11,11,11,11,11,12
        db 12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12
        ; tile 5: Empty block
        db 12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12
        db 12, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8,12
        db 12, 8, 3, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 3, 8,12
        db 12, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8,12
        db 12, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8,12
        db 12, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8,12
        db 12, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8,12
        db 12, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8,12
        db 12, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8,12
        db 12, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8,12
        db 12, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8,12
        db 12, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8,12
        db 12, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8,12
        db 12, 8, 3, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 3, 8,12
        db 12, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8,12
        db 12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12
        ; tile 6: Pipe top-left
        db 12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12
        db 12, 5,15,15, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5
        db 12, 5,15,15, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5
        db 12, 5,15,15, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5
        db 12, 5,15,15, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5
        db 12, 5,15,15, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5
        db 12, 5,15,15, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5
        db 12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12
        db  1, 1,12, 5,15,15, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5
        db  1, 1,12, 5,15,15, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5
        db  1, 1,12, 5,15,15, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5
        db  1, 1,12, 5,15,15, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5
        db  1, 1,12, 5,15,15, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5
        db  1, 1,12, 5,15,15, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5
        db  1, 1,12, 5,15,15, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5
        db  1, 1,12, 5,15,15, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5
        ; tile 7: Pipe top-right
        db 12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12
        db  5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 2, 2, 2, 2, 5,12
        db  5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 2, 2, 2, 2, 5,12
        db  5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 2, 2, 2, 2, 5,12
        db  5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 2, 2, 2, 2, 5,12
        db  5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 2, 2, 2, 2, 5,12
        db  5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 2, 2, 2, 2, 5,12
        db 12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12
        db  5, 5, 5, 5, 5, 5, 5, 5, 2, 2, 2, 2, 5,12, 1, 1
        db  5, 5, 5, 5, 5, 5, 5, 5, 2, 2, 2, 2, 5,12, 1, 1
        db  5, 5, 5, 5, 5, 5, 5, 5, 2, 2, 2, 2, 5,12, 1, 1
        db  5, 5, 5, 5, 5, 5, 5, 5, 2, 2, 2, 2, 5,12, 1, 1
        db  5, 5, 5, 5, 5, 5, 5, 5, 2, 2, 2, 2, 5,12, 1, 1
        db  5, 5, 5, 5, 5, 5, 5, 5, 2, 2, 2, 2, 5,12, 1, 1
        db  5, 5, 5, 5, 5, 5, 5, 5, 2, 2, 2, 2, 5,12, 1, 1
        db  5, 5, 5, 5, 5, 5, 5, 5, 2, 2, 2, 2, 5,12, 1, 1
        ; tile 8: Pipe body-left
        db  1, 1,12, 5,15,15, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5
        db  1, 1,12, 5,15,15, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5
        db  1, 1,12, 5,15,15, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5
        db  1, 1,12, 5,15,15, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5
        db  1, 1,12, 5,15,15, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5
        db  1, 1,12, 5,15,15, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5
        db  1, 1,12, 5,15,15, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5
        db  1, 1,12, 5,15,15, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5
        db  1, 1,12, 5,15,15, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5
        db  1, 1,12, 5,15,15, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5
        db  1, 1,12, 5,15,15, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5
        db  1, 1,12, 5,15,15, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5
        db  1, 1,12, 5,15,15, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5
        db  1, 1,12, 5,15,15, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5
        db  1, 1,12, 5,15,15, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5
        db  1, 1,12, 5,15,15, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5
        ; tile 9: Pipe body-right
        db  5, 5, 5, 5, 5, 5, 5, 5, 2, 2, 2, 2, 5,12, 1, 1
        db  5, 5, 5, 5, 5, 5, 5, 5, 2, 2, 2, 2, 5,12, 1, 1
        db  5, 5, 5, 5, 5, 5, 5, 5, 2, 2, 2, 2, 5,12, 1, 1
        db  5, 5, 5, 5, 5, 5, 5, 5, 2, 2, 2, 2, 5,12, 1, 1
        db  5, 5, 5, 5, 5, 5, 5, 5, 2, 2, 2, 2, 5,12, 1, 1
        db  5, 5, 5, 5, 5, 5, 5, 5, 2, 2, 2, 2, 5,12, 1, 1
        db  5, 5, 5, 5, 5, 5, 5, 5, 2, 2, 2, 2, 5,12, 1, 1
        db  5, 5, 5, 5, 5, 5, 5, 5, 2, 2, 2, 2, 5,12, 1, 1
        db  5, 5, 5, 5, 5, 5, 5, 5, 2, 2, 2, 2, 5,12, 1, 1
        db  5, 5, 5, 5, 5, 5, 5, 5, 2, 2, 2, 2, 5,12, 1, 1
        db  5, 5, 5, 5, 5, 5, 5, 5, 2, 2, 2, 2, 5,12, 1, 1
        db  5, 5, 5, 5, 5, 5, 5, 5, 2, 2, 2, 2, 5,12, 1, 1
        db  5, 5, 5, 5, 5, 5, 5, 5, 2, 2, 2, 2, 5,12, 1, 1
        db  5, 5, 5, 5, 5, 5, 5, 5, 2, 2, 2, 2, 5,12, 1, 1
        db  5, 5, 5, 5, 5, 5, 5, 5, 2, 2, 2, 2, 5,12, 1, 1
        db  5, 5, 5, 5, 5, 5, 5, 5, 2, 2, 2, 2, 5,12, 1, 1
        ; tile 10: Stair block
        db 12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12
        db 12, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7,12
        db 12, 7,13,13,13,13,13,13,13,13,13,13,13,13, 3,12
        db 12, 7,13,13,13,13,13,13,13,13,13,13,13,13, 3,12
        db 12, 7,13,13,13,13,13,13,13,13,13,13,13,13, 3,12
        db 12, 7,13,13,13,13,13,13,13,13,13,13,13,13, 3,12
        db 12, 7,13,13,13,13,13,13,13,13,13,13,13,13, 3,12
        db 12, 7,13,13,13,13,13,13,13,13,13,13,13,13, 3,12
        db 12, 7,13,13,13,13,13,13,13,13,13,13,13,13, 3,12
        db 12, 7,13,13,13,13,13,13,13,13,13,13,13,13, 3,12
        db 12, 7,13,13,13,13,13,13,13,13,13,13,13,13, 3,12
        db 12, 7,13,13,13,13,13,13,13,13,13,13,13,13, 3,12
        db 12, 7,13,13,13,13,13,13,13,13,13,13,13,13, 3,12
        db 12, 7,13,13,13,13,13,13,13,13,13,13,13,13, 3,12
        db 12, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3,12
        db 12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12
        ; tile 11: Coin
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 1,12,12,12,12, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1,12,11,11,11,11,12, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1,12,11,10,11,11,12, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1,12,11,10,11,11,12, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1,12,11,10,11,11,12, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1,12,11,10,11,11,12, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1,12,11,10,11,11,12, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1,12,11,10,11,11,12, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1,12,11,10,11,11,12, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1,12,11,10,11,11,12, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1,12,11,11,11,11,12, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 1,12,12,12,12, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        ; tile 12: Flag pole
        db  1, 1, 1, 1, 1, 1, 1,15, 5, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 1, 1,15, 5, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 1, 1,15, 5, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 1, 1,15, 5, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 1, 1,15, 5, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 1, 1,15, 5, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 1, 1,15, 5, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 1, 1,15, 5, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 1, 1,15, 5, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 1, 1,15, 5, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 1, 1,15, 5, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 1, 1,15, 5, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 1, 1,15, 5, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 1, 1,15, 5, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 1, 1,15, 5, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 1, 1,15, 5, 1, 1, 1, 1, 1, 1, 1
        ; tile 13: Flag pole top
        db  1, 1, 1, 1, 1, 1, 1,15,15, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 1,15,15,15,15, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 1,15,15,15,15, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 1, 1,15, 5, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 9, 9,15, 5, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 9, 9, 9, 9,15, 5, 1, 1, 1, 1, 1, 1, 1
        db  1, 9, 9, 9, 9, 9, 9,15, 5, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 9, 9, 9, 9,15, 5, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 9, 9,15, 5, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 1, 1,15, 5, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 1, 1,15, 5, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 1, 1,15, 5, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 1, 1,15, 5, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 1, 1,15, 5, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 1, 1,15, 5, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 1, 1,15, 5, 1, 1, 1, 1, 1, 1, 1
        ; tile 14: Scenery (no collision)
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 9, 9, 9
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 9, 9, 9, 9, 9
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 9, 9, 9, 9, 9, 9
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 9, 9, 9, 9, 9, 9, 9
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 9, 9, 9, 9, 9, 9, 9
        db  1, 1, 1, 1, 1, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9
        db  1, 1, 1, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9
        db  1, 1, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9
        db  1, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9
        ; tile 15: Scenery (no collision)
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db  9, 9, 9, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db  9, 9, 9, 9, 9, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db  9, 9, 9, 9, 9, 9, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db  9, 9, 9, 9, 9, 9, 9, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db  9, 9, 9, 9, 9, 9, 9, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db  9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 1, 1, 1, 1, 1
        db  9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 1, 1, 1
        db  9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 1, 1
        db  9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 1
        ; tile 16: Scenery (no collision)
        db  1, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9
        db  9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9
        db  9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9
        db  9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9
        db  9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9
        db  9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9
        db  9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9
        db  1, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9
        db  1, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9
        db  1, 1, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9
        db  1, 1, 1, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9
        db  1, 1, 1, 1, 1, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        ; tile 17: Scenery (no collision)
        db  9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 1
        db  9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9
        db  9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9
        db  9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9
        db  9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9
        db  9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9
        db  9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9
        db  9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 1
        db  9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 1
        db  9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 1, 1
        db  9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 1, 1, 1
        db  9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        ; tile 18: Scenery (no collision)
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 9
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 9, 9
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 9, 9
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 9, 9, 9
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 9, 9, 9
        db  1, 1, 1, 1, 1, 9, 9, 9, 9, 9, 9, 1, 1, 9, 9, 9
        db  1, 1, 1, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9
        db  1, 1, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9
        db  1, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9
        ; tile 19: Scenery (no collision)
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 9, 9, 9, 9, 9, 9, 1, 1, 1, 1, 1, 1, 1
        db  1, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 1, 1, 1, 1, 1
        db  9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 1, 1, 1, 1
        db  9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 1, 1, 1
        db  9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 1, 1
        db  9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 1, 1
        db  9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 1
        db  9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 1
        db  9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 1
        db  9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 1
        db  9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 1
        db  9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 1
        ; tile 20: Scenery (no collision)
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 9, 9, 9, 9, 9, 9, 1, 1, 1, 1, 1
        db  1, 1, 1, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 1, 1, 1
        db  1, 1, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 1, 1
        db  1, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 1
        ; tile 21: Scenery (no collision)
        db  9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 1, 1
        db  9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 1, 1
        db  9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 1, 1, 1
        db  9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 1, 1, 1, 1
        db  9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9
        db  9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9
        db  9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9
        db  9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9
        db  9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9
        db  9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9
        db  9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9
        db  9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        ; tile 22: Scenery (no collision)
        db  1, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 1
        db  9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9
        db  9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9
        db  9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9
        db  9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9
        db  9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9
        db  9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9
        db  9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 1
        db  9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 1
        db  9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 1, 1
        db  9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 1, 1, 1
        db  9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        ; tile 23: Scenery (no collision)
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 9, 9, 9, 9, 9, 9, 1, 1, 1, 1, 1
        db  1, 1, 1, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 1, 1, 9
        db  1, 1, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9
        db  1, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9
        ; tile 24: Scenery (no collision)
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 9, 9, 9, 9, 9
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 9, 9, 9, 9, 9, 9, 9
        db  1, 1, 1, 1, 1, 1, 1, 1, 9, 9, 9, 9, 9, 9, 9, 9
        db  1, 1, 1, 1, 1, 1, 1, 9, 9, 9, 9, 9, 9, 9, 9, 9
        db  1, 1, 1, 1, 1, 1, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9
        db  1, 1, 1, 1, 1, 1, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9
        db  1, 1, 1, 1, 1, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9
        db  1, 1, 1, 1, 1, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9
        db  1, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9
        db  9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9
        db  9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9
        db  9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9
        ; tile 25: Scenery (no collision)
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db  9, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db  9, 9, 9, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db  9, 9, 9, 9, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db  9, 9, 9, 9, 9, 1, 1, 1, 1, 9, 9, 9, 9, 9, 9, 1
        db  9, 9, 9, 9, 9, 9, 1, 1, 9, 9, 9, 9, 9, 9, 9, 9
        db  9, 9, 9, 9, 9, 9, 1, 9, 9, 9, 9, 9, 9, 9, 9, 9
        db  9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9
        db  9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9
        db  9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9
        db  9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9
        db  9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9
        db  9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9
        ; tile 26: Scenery (no collision)
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db  9, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db  9, 9, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db  9, 9, 9, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db  9, 9, 9, 1, 1, 9, 9, 9, 9, 9, 9, 1, 1, 1, 1, 1
        db  9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 1, 1, 1
        db  9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 1, 1
        db  9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 1
        ; tile 27: Scenery (no collision)
        db  9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9
        db  9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9
        db  9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9
        db  9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9
        db  9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9
        db  9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9
        db  9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9
        db  9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9
        db  9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9
        db  9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9
        db  9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9
        db  9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        ; tile 28: Scenery (no collision)
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,12,12
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,12, 2, 2
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,12, 2, 2, 2
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1,12,12, 2, 2, 2, 2
        db  1, 1, 1, 1, 1, 1, 1, 1, 1,12, 2, 2, 2, 2, 2, 2
        db  1, 1, 1, 1, 1, 1, 1, 1,12, 2, 2, 2, 2, 2, 2, 2
        db  1, 1, 1, 1, 1, 1, 1,12, 2, 2, 2, 2, 2, 2, 2, 2
        db  1, 1, 1, 1, 1, 1, 1,12, 2, 2, 2, 2, 2, 2, 2, 2
        db  1, 1, 1, 1, 1, 1,12, 2, 2, 2, 2, 2, 2, 2, 2, 2
        ; tile 29: Scenery (no collision)
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,12,12,12,12
        db  1, 1, 1, 1, 1, 1, 1, 1, 1,12,12,12, 2, 2, 2, 2
        db  1, 1, 1, 1, 1, 1,12,12,12, 2, 2, 2, 2, 2, 2, 2
        db  1, 1, 1, 1,12,12, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2
        db  1, 1,12,12, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2
        db 12,12, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2
        db  2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2
        db  2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2
        db  2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2
        db  2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2
        db  2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2
        db  2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2
        db  2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2
        db  2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2
        db  2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2
        ; tile 30: Scenery (no collision)
        db  1,12,12,12,12,12,12,12,12,12,12,12,12,12,12, 1
        db 12, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,12
        db  2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2
        db  2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2
        db  2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2
        db  2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2
        db  2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2
        db  2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2
        db  2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2
        db  2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2
        db  2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2
        db  2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2
        db  2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2
        db  2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2
        db  2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,12,12
        db  2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,12,12
        ; tile 31: Scenery (no collision)
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db 12,12,12,12, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db  2, 2, 2, 2,12,12,12, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db  2, 2, 2, 2, 2, 2, 2,12,12,12, 1, 1, 1, 1, 1, 1
        db  2, 2, 2, 2, 2, 2, 2, 2, 2, 2,12,12, 1, 1, 1, 1
        db  2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,12,12, 1, 1
        db  2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,12,12
        db  2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2
        db  2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2
        db  2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2
        db  2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2
        db  2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2
        db  2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2
        db  2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2
        db  2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2
        db  2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2
        ; tile 32: Scenery (no collision)
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db 12,12, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db  2, 2,12, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db  2, 2, 2,12, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db  2, 2, 2, 2,12,12, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db  2, 2, 2, 2, 2, 2,12, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db  2, 2, 2, 2, 2, 2, 2,12, 1, 1, 1, 1, 1, 1, 1, 1
        db  2, 2, 2, 2, 2, 2, 2, 2,12, 1, 1, 1, 1, 1, 1, 1
        db  2, 2, 2, 2, 2, 2, 2, 2,12, 1, 1, 1, 1, 1, 1, 1
        db  2, 2, 2, 2, 2, 2, 2, 2, 2,12, 1, 1, 1, 1, 1, 1
        ; tile 33: Scenery (no collision)
        db  1, 1, 1, 1, 1,12, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2
        db  1, 1, 1, 1,12, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2
        db  1, 1, 1, 1,12, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2
        db  1, 1, 1,12, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2
        db  1, 1, 1,12, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2
        db  1, 1,12, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2
        db  1, 1,12, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2
        db  1,12, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2
        db  1,12, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2
        db  1,12, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2
        db  1,12, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2
        db 12, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2
        db 12, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2
        db 12, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2
        db 12, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2
        db 12, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2
        ; tile 34: Scenery (no collision)
        db  2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2
        db  2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2
        db  2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,12,12
        db  2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,12,12
        db  2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,12,12
        db  2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,12,12
        db  2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2
        db  2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2
        db  2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2
        db  2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2
        db  2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2
        db  2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2
        db  2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2
        db  2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2
        db  2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2
        db  2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2
        ; tile 35: Scenery (no collision)
        db  2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,12,12
        db  2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,12,12
        db  2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2
        db  2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2
        db  2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2
        db  2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2
        db  2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2
        db  2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2
        db  2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2
        db  2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2
        db  2, 2, 2, 2, 2, 2, 2, 2, 2, 2,12,12, 2, 2, 2, 2
        db  2, 2, 2, 2, 2, 2, 2, 2, 2, 2,12,12, 2, 2, 2, 2
        db  2, 2, 2, 2, 2, 2, 2, 2, 2, 2,12,12, 2, 2, 2, 2
        db  2, 2, 2, 2, 2, 2, 2, 2, 2, 2,12,12, 2, 2, 2, 2
        db  2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2
        db  2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2
        ; tile 36: Scenery (no collision)
        db  2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2
        db  2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2
        db  2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2
        db  2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2
        db  2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2
        db  2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2
        db  2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2
        db  2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2
        db  2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2
        db  2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2
        db  2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2
        db  2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2
        db  2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2
        db  2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2
        db  2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2
        db  2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2
        ; tile 37: Scenery (no collision)
        db  2, 2, 2, 2, 2, 2, 2, 2, 2, 2,12, 1, 1, 1, 1, 1
        db  2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,12, 1, 1, 1, 1
        db  2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,12, 1, 1, 1, 1
        db  2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,12, 1, 1, 1
        db  2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,12, 1, 1, 1
        db  2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,12, 1, 1
        db  2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,12, 1, 1
        db  2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,12, 1
        db  2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,12, 1
        db  2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,12, 1
        db  2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,12, 1
        db  2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,12
        db  2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,12
        db  2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,12
        db  2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,12
        db  2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,12
        ; tile 38: Scenery (no collision)
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,12,12
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,12,12,12, 2, 2
        db  1, 1, 1, 1, 1, 1, 1, 1, 1,12,12, 2, 2, 2, 2, 2
        db  1, 1, 1, 1, 1, 1, 1,12,12, 2, 2, 2, 2, 2, 2, 2
        db  1, 1, 1, 1, 1, 1,12, 2, 2, 2, 2, 2, 2, 2, 2, 2
        db  1, 1, 1, 1, 1,12, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2
        db  1, 1, 1, 1,12, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2
        db  1, 1, 1,12, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2
        db  1, 1,12, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2
        db  1,12, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2
        db  1,12, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2
        db  1,12, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2
        db 12, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2
        db 12, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2
        db 12, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2
        ; tile 39: Scenery (no collision)
        db  1, 1,12,12,12,12,12,12,12,12,12,12,12,12, 1, 1
        db 12,12, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,12,12
        db  2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2
        db  2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2
        db  2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2
        db  2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2
        db  2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2
        db  2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2
        db  2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,12,12, 2, 2, 2
        db  2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,12,12, 2, 2, 2
        db  2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,12,12, 2, 2, 2
        db  2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,12,12, 2, 2, 2
        db  2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2
        db  2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2
        db  2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2
        db  2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2
        ; tile 40: Scenery (no collision)
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db 12,12, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db  2, 2,12,12,12, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db  2, 2, 2, 2, 2,12,12, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db  2, 2, 2, 2, 2, 2, 2,12,12, 1, 1, 1, 1, 1, 1, 1
        db  2, 2, 2, 2, 2, 2, 2, 2, 2,12, 1, 1, 1, 1, 1, 1
        db  2, 2, 2, 2, 2, 2, 2, 2, 2, 2,12, 1, 1, 1, 1, 1
        db  2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,12, 1, 1, 1, 1
        db  2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,12, 1, 1, 1
        db  2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,12, 1, 1
        db  2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,12, 1
        db  2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,12, 1
        db  2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,12, 1
        db  2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,12
        db  2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,12
        db  2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,12
        ; tile 41: Scenery (no collision)
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 2, 2, 2
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 2,15,15,15
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 2,15,15,15,15
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 2,15,15,15,15,15
        db  1, 1, 1, 1, 1, 2, 2, 2, 2, 2,15,15,15,15,15,15
        db  1, 1, 1, 2, 2,15,15,15,15,15,15,15,15,15,15,15
        db  1, 1, 1, 2,15,15,15,15,15,15,15,15,15,15,15,15
        db  1, 1, 2,15,15,15,15,15,15,15,15,15,15,15,15,15
        db  1, 1, 2,15,15,15,15,15,15,15,15,15,15,15,15,15
        db  1, 1, 2,15,15,15,15,15,15,15,15,15,15,15,15,15
        db  1, 1, 2,15,15,15,15,15,15,15,15,15,15,15,15,15
        db  1, 1, 2,15,15,15,15,15,15,15,15,15,15,15,15,15
        db  1, 1, 2,15,15,15,15,15,15,15,15,15,15,15,15,15
        db  1, 1, 1, 2,15,15,15,15,15,15,15,15,15,15,15,15
        db  1, 1, 1, 2, 2,15,15,15,15,15,15,15,15,15,15,15
        db  1, 1, 1, 1, 1, 2,15,15,15,15,15,15,15,15,15,15
        ; tile 42: Scenery (no collision)
        db  2, 2, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db 15,15,15, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db 15,15,15,15, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db 15,15,15,15,15, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db 15,15,15,15,15,15, 2, 2, 2, 2, 2, 1, 1, 1, 1, 1
        db 15,15,15,15,15,15,15,15,15,15,15, 2, 2, 1, 1, 1
        db 15,15,15,15,15,15,15,15,15,15,15,15, 2, 1, 1, 1
        db 15,15,15,15,15,15,15,15,15,15,15,15,15, 2, 1, 1
        db 15,15,15,15,15,15,15,15,15,15,15,15,15, 2, 1, 1
        db 15,15,15,15,15,15,15,15,15,15,15,15,15, 2, 1, 1
        db 15,15,15,15,15,15,15,15,15,15,15,15,15, 2, 1, 1
        db 15,15,15,15,15,15,15,15,15,15,15,15,15, 2, 1, 1
        db 15,15,15,15,15,15,15,15,15,15,15,15,15, 2, 1, 1
        db 15,15,15,15,15,15,15,15,15,15,15,15, 2, 1, 1, 1
        db 15,15,15,15,15,15,15,15,15,15,15, 2, 2, 1, 1, 1
        db 15,15,15,15,15,15,15,15,15,15, 2, 1, 1, 1, 1, 1
        ; tile 43: Scenery (no collision)
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 2, 2, 2, 2, 2, 2, 1, 1, 1, 1, 1
        db  1, 1, 1, 2, 2,15,15,15,15,15,15, 2, 2, 1, 1, 2
        db  1, 1, 1, 2,15,15,15,15,15,15,15,15, 2, 1, 1, 2
        db  1, 1, 2,15,15,15,15,15,15,15,15,15,15, 2, 2,15
        db  1, 1, 2,15,15,15,15,15,15,15,15,15,15,15,15,15
        db  1, 1, 2,15,15,15,15,15,15,15,15,15,15,15,15,15
        db  1, 1, 2,15,15,15,15,15,15,15,15,15,15,15,15,15
        db  1, 1, 2,15,15,15,15,15,15,15,15,15,15,15,15,15
        db  1, 1, 2,15,15,15,15,15,15,15,15,15,15,15,15,15
        db  1, 1, 1, 2,15,15,15,15,15,15,15,15,15,15,15,15
        db  1, 1, 1, 2, 2,15,15,15,15,15,15,15,15,15,15,15
        db  1, 1, 1, 1, 1, 2,15,15,15,15,15,15,15,15,15,15
        ; tile 44: Scenery (no collision)
        db  1, 1, 1, 1, 1, 2, 2, 2, 2, 2, 2, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 2,15,15,15,15,15,15, 2, 1, 1, 1, 1
        db  1, 1, 1, 2,15,15,15,15,15,15,15,15, 2, 1, 1, 1
        db  1, 1, 2,15,15,15,15,15,15,15,15,15,15, 2, 1, 1
        db  1, 2,15,15,15,15,15,15,15,15,15,15,15,15, 2, 1
        db  2,15,15,15,15,15,15,15,15,15,15,15,15,15, 2, 1
        db 15,15,15,15,15,15,15,15,15,15,15,15,15,15, 2, 1
        db 15,15,15,15,15,15,15,15,15,15,15,15,15,15, 2, 1
        db 15,15,15,15,15,15,15,15,15,15,15,15,15,15, 2, 1
        db 15,15,15,15,15,15,15,15,15,15,15,15,15,15, 2, 1
        db 15,15,15,15,15,15,15,15,15,15,15,15,15,15,15, 2
        db 15,15,15,15,15,15,15,15,15,15,15,15,15,15,15,15
        db 15,15,15,15,15,15,15,15,15,15,15,15,15,15,15,15
        db 15,15,15,15,15,15,15,15,15,15,15,15,15,15,15,15
        db 15,15,15,15,15,15,15,15,15,15,15,15,15,15,15,15
        db 15,15,15,15,15,15,15,15,15,15,15,15,15,15,15,15
        ; tile 45: Scenery (no collision)
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 2, 2, 2, 2, 2, 2, 1, 1, 1, 1, 1
        db  1, 1, 1, 2, 2,15,15,15,15,15,15, 2, 2, 1, 1, 1
        db  1, 1, 1, 2,15,15,15,15,15,15,15,15, 2, 1, 1, 1
        db  1, 1, 2,15,15,15,15,15,15,15,15,15,15, 2, 1, 1
        db  1, 1, 2,15,15,15,15,15,15,15,15,15,15, 2, 1, 1
        db  1, 1, 2,15,15,15,15,15,15,15,15,15,15, 2, 1, 1
        db  2, 2,15,15,15,15,15,15,15,15,15,15,15, 2, 1, 1
        db 15,15,15,15,15,15,15,15,15,15,15,15,15, 2, 1, 1
        db 15,15,15,15,15,15,15,15,15,15,15,15,15, 2, 1, 1
        db 15,15,15,15,15,15,15,15,15,15,15,15, 2, 1, 1, 1
        db 15,15,15,15,15,15,15,15,15,15,15, 2, 2, 1, 1, 1
        db 15,15,15,15,15,15,15,15,15,15, 2, 1, 1, 1, 1, 1
        ; tile 46: Scenery (no collision)
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 2, 2, 2
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 2,15,15,15
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 2,15,15,15,15
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 2,15,15,15,15,15
        db  1, 2, 2, 2, 2, 2, 2, 1, 1, 2,15,15,15,15,15,15
        db  2,15,15,15,15,15,15, 2, 2,15,15,15,15,15,15,15
        db 15,15,15,15,15,15,15,15,15,15,15,15,15,15,15,15
        db 15,15,15,15,15,15,15,15,15,15,15,15,15,15,15,15
        db 15,15,15,15,15,15,15,15,15,15,15,15,15,15,15,15
        db 15,15,15,15,15,15,15,15,15,15,15,15,15,15,15,15
        db 15,15,15,15,15,15,15,15,15,15,15,15,15,15,15,15
        db 15,15,15,15,15,15,15,15,15,15,15,15,15,15,15,15
        db 15,15,15,15,15,15,15,15,15,15,15,15,15,15,15,15
        db 15,15,15,15,15,15,15,15,15,15,15,15,15,15,15,15
        db 15,15,15,15,15,15,15,15,15,15,15,15,15,15,15,15
        db 15,15,15,15,15,15,15,15,15,15,15,15,15,15,15,15
        ; tile 47: Scenery (no collision)
        db  2, 2, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db 15,15,15, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db 15,15,15,15, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db 15,15,15,15,15, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db 15,15,15,15,15,15, 2, 1, 1, 2, 2, 2, 2, 2, 2, 1
        db 15,15,15,15,15,15,15, 2, 2,15,15,15,15,15,15, 2
        db 15,15,15,15,15,15,15,15,15,15,15,15,15,15,15,15
        db 15,15,15,15,15,15,15,15,15,15,15,15,15,15,15,15
        db 15,15,15,15,15,15,15,15,15,15,15,15,15,15,15,15
        db 15,15,15,15,15,15,15,15,15,15,15,15,15,15,15,15
        db 15,15,15,15,15,15,15,15,15,15,15,15,15,15,15,15
        db 15,15,15,15,15,15,15,15,15,15,15,15,15,15,15,15
        db 15,15,15,15,15,15,15,15,15,15,15,15,15,15,15,15
        db 15,15,15,15,15,15,15,15,15,15,15,15,15,15,15,15
        db 15,15,15,15,15,15,15,15,15,15,15,15,15,15,15,15
        db 15,15,15,15,15,15,15,15,15,15,15,15,15,15,15,15
        ; tile 48: Scenery (no collision)
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        db  1, 1, 1, 1, 1, 2, 2, 2, 2, 2, 2, 1, 1, 1, 1, 1
        db  2, 1, 1, 2, 2,15,15,15,15,15,15, 2, 2, 1, 1, 1
        db  2, 1, 1, 2,15,15,15,15,15,15,15,15, 2, 1, 1, 1
        db 15, 2, 2,15,15,15,15,15,15,15,15,15,15, 2, 1, 1
        db 15,15,15,15,15,15,15,15,15,15,15,15,15, 2, 1, 1
        db 15,15,15,15,15,15,15,15,15,15,15,15,15, 2, 1, 1
        db 15,15,15,15,15,15,15,15,15,15,15,15,15, 2, 1, 1
        db 15,15,15,15,15,15,15,15,15,15,15,15,15, 2, 1, 1
        db 15,15,15,15,15,15,15,15,15,15,15,15,15, 2, 1, 1
        db 15,15,15,15,15,15,15,15,15,15,15,15, 2, 1, 1, 1
        db 15,15,15,15,15,15,15,15,15,15,15, 2, 2, 1, 1, 1
        db 15,15,15,15,15,15,15,15,15,15, 2, 1, 1, 1, 1, 1
        ; tile 49: Scenery (no collision)
        db  1, 1, 1, 1, 4, 4, 4,12, 1, 1, 1, 1, 4, 4, 4,12
        db  1, 1, 1, 1, 4, 4, 4,12, 1, 1, 1, 1, 4, 4, 4,12
        db  1, 1, 1, 1, 4, 4, 4,12, 1, 1, 1, 1, 4, 4, 4,12
        db  1, 1, 1, 1,12,12,12,12, 1, 1, 1, 1,12,12,12,12
        db  4, 4, 4,12, 4, 4, 4, 4, 4, 4, 4,12, 4, 4, 4, 4
        db  4, 4, 4,12, 4, 4, 0, 0, 0, 0, 4,12, 4, 4, 4, 4
        db  4, 4, 4,12, 4, 0, 0, 0, 0, 0, 0,12, 4, 4, 4, 4
        db 12,12,12,12,12, 0, 0, 0, 0, 0, 0,12,12,12,12,12
        db  4, 4, 4, 4, 4, 0, 0, 0, 0, 0, 0, 4, 4, 4, 4,12
        db  4, 4, 4, 4, 4, 0, 0, 0, 0, 0, 0, 4, 4, 4, 4,12
        db  4, 4, 4, 4, 4, 0, 0, 0, 0, 0, 0, 4, 4, 4, 4,12
        db 12,12,12,12,12, 0, 0, 0, 0, 0, 0,12,12,12,12,12
        db  4, 4, 4,12, 4, 0, 0, 0, 0, 0, 0,12, 4, 4, 4, 4
        db  4, 4, 4,12, 4, 0, 0, 0, 0, 0, 0,12, 4, 4, 4, 4
        db  4, 4, 4,12, 4, 4, 4, 4, 4, 4, 4,12, 4, 4, 4, 4
        db 12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12
        ; tile 50: Scenery (no collision)
        db  1, 1, 1, 1, 4, 4, 4,12, 1, 1, 1, 1, 4, 4, 4,12
        db  1, 1, 1, 1, 4, 4, 4,12, 1, 1, 1, 1, 4, 4, 4,12
        db  1, 1, 1, 1, 4, 4, 4,12, 1, 1, 1, 1, 4, 4, 4,12
        db  1, 1, 1, 1,12,12,12,12, 1, 1, 1, 1,12,12,12,12
        db  4, 4, 4,12, 4, 4, 4, 4, 4, 4, 4,12, 4, 4, 4, 4
        db  4, 4, 4,12, 4, 4, 4, 4, 4, 4, 4,12, 4, 4, 4, 4
        db  4, 4, 4,12, 4, 4, 4, 4, 4, 4, 4,12, 4, 4, 4, 4
        db 12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12
        db  4, 4, 4, 4, 4, 4, 4, 0, 0, 0, 0, 4, 4, 4, 4,12
        db  4, 4, 4, 4, 4, 4, 0, 0, 0, 0, 0, 0, 4, 4, 4,12
        db  4, 4, 4, 4, 4, 4, 0, 0, 0, 0, 0, 0, 4, 4, 4,12
        db 12,12,12,12,12,12, 0, 0, 0, 0, 0, 0,12,12,12,12
        db  4, 4, 4,12, 4, 4, 0, 0, 0, 0, 0, 0, 4, 4, 4, 4
        db  4, 4, 4,12, 4, 4, 0, 0, 0, 0, 0, 0, 4, 4, 4, 4
        db  4, 4, 4,12, 4, 4, 0, 0, 0, 0, 0, 0, 4, 4, 4, 4
        db 12,12,12,12,12,12, 0, 0, 0, 0, 0, 0,12,12,12,12
        ; tile 51: Scenery (no collision)
        db  4, 4, 4, 4, 4, 4, 4,12, 4, 4, 4, 4, 4, 4, 4,12
        db  4, 4, 4, 4, 4, 4, 4,12, 4, 4, 4, 4, 4, 4, 4,12
        db  4, 4, 4, 4, 4, 4, 4,12, 4, 4, 4, 4, 4, 4, 4,12
        db 12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12
        db  4, 4, 4,12, 4, 4, 4, 4, 4, 4, 4,12, 4, 4, 4, 4
        db  4, 4, 4,12, 4, 4, 4, 4, 4, 4, 4,12, 4, 4, 4, 4
        db  4, 4, 4,12, 4, 4, 4, 4, 4, 4, 4,12, 4, 4, 4, 4
        db 12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12
        db  4, 4, 4, 4, 4, 4, 4,12, 4, 4, 4, 4, 4, 4, 4,12
        db  4, 4, 4, 4, 4, 4, 4,12, 4, 4, 4, 4, 4, 4, 4,12
        db  4, 4, 4, 4, 4, 4, 4,12, 4, 4, 4, 4, 4, 4, 4,12
        db 12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12
        db  4, 4, 4,12, 4, 4, 4, 4, 4, 4, 4,12, 4, 4, 4, 4
        db  4, 4, 4,12, 4, 4, 4, 4, 4, 4, 4,12, 4, 4, 4, 4
        db  4, 4, 4,12, 4, 4, 4, 4, 4, 4, 4,12, 4, 4, 4, 4
        db 12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12
        ; tile 52: Scenery (no collision)
        db  1, 1, 1, 1, 4, 4, 4,12, 1, 1, 1, 1, 4, 4, 4,12
        db  1, 1, 1, 1, 4, 4, 4,12, 1, 1, 1, 1, 4, 4, 4,12
        db  1, 1, 1, 1, 4, 4, 4,12, 1, 1, 1, 1, 4, 4, 4,12
        db  1, 1, 1, 1,12,12,12,12, 1, 1, 1, 1,12,12,12,12
        db  4, 4, 4,12, 4, 4, 4, 4, 4, 4, 4,12, 4, 4, 4, 4
        db  4, 4, 4,12, 4, 4, 4, 4, 4, 4, 4,12, 4, 4, 4, 4
        db  4, 4, 4,12, 4, 4, 4, 4, 4, 4, 4,12, 4, 4, 4, 4
        db 12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12
        db  4, 4, 4, 4, 4, 0, 0, 0, 0, 4, 4, 4, 4, 4, 4,12
        db  4, 4, 4, 4, 0, 0, 0, 0, 0, 0, 4, 4, 4, 4, 4,12
        db  4, 4, 4, 4, 0, 0, 0, 0, 0, 0, 4, 4, 4, 4, 4,12
        db 12,12,12,12, 0, 0, 0, 0, 0, 0,12,12,12,12,12,12
        db  4, 4, 4,12, 0, 0, 0, 0, 0, 0, 4,12, 4, 4, 4, 4
        db  4, 4, 4,12, 0, 0, 0, 0, 0, 0, 4,12, 4, 4, 4, 4
        db  4, 4, 4,12, 0, 0, 0, 0, 0, 0, 4,12, 4, 4, 4, 4
        db 12,12,12,12, 0, 0, 0, 0, 0, 0,12,12,12,12,12,12
        ; tile 53: Scenery (no collision)
        db  4, 4, 4, 4, 4, 4, 0, 0, 0, 0, 0, 0, 4, 4, 4,12
        db  4, 4, 4, 4, 4, 4, 0, 0, 0, 0, 0, 0, 4, 4, 4,12
        db  4, 4, 4, 4, 4, 4, 0, 0, 0, 0, 0, 0, 4, 4, 4,12
        db 12,12,12,12,12,12, 0, 0, 0, 0, 0, 0,12,12,12,12
        db  4, 4, 4,12, 4, 4, 4, 4, 4, 4, 4,12, 4, 4, 4, 4
        db  4, 4, 4,12, 4, 4, 4, 4, 4, 4, 4,12, 4, 4, 4, 4
        db  4, 4, 4,12, 4, 4, 4, 4, 4, 4, 4,12, 4, 4, 4, 4
        db 12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12
        db  4, 4, 4, 4, 4, 4, 4,12, 4, 4, 4, 4, 4, 4, 4,12
        db  4, 4, 4, 4, 4, 4, 4,12, 4, 4, 4, 4, 4, 4, 4,12
        db  4, 4, 4, 4, 4, 4, 4,12, 4, 4, 4, 4, 4, 4, 4,12
        db 12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12
        db  4, 4, 4,12, 4, 4, 4, 4, 4, 4, 4,12, 4, 4, 4, 4
        db  4, 4, 4,12, 4, 4, 4, 4, 4, 4, 4,12, 4, 4, 4, 4
        db  4, 4, 4,12, 4, 4, 4, 4, 4, 4, 4,12, 4, 4, 4, 4
        db 12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12
        ; tile 54: Scenery (no collision)
        db  4, 4, 4, 4, 0, 0, 0, 0, 0, 0, 4, 4, 4, 4, 4,12
        db  4, 4, 4, 4, 0, 0, 0, 0, 0, 0, 4, 4, 4, 4, 4,12
        db  4, 4, 4, 4, 0, 0, 0, 0, 0, 0, 4, 4, 4, 4, 4,12
        db 12,12,12,12, 0, 0, 0, 0, 0, 0,12,12,12,12,12,12
        db  4, 4, 4,12, 4, 4, 4, 4, 4, 4, 4,12, 4, 4, 4, 4
        db  4, 4, 4,12, 4, 4, 4, 4, 4, 4, 4,12, 4, 4, 4, 4
        db  4, 4, 4,12, 4, 4, 4, 4, 4, 4, 4,12, 4, 4, 4, 4
        db 12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12
        db  4, 4, 4, 4, 4, 4, 4,12, 4, 4, 4, 4, 4, 4, 4,12
        db  4, 4, 4, 4, 4, 4, 4,12, 4, 4, 4, 4, 4, 4, 4,12
        db  4, 4, 4, 4, 4, 4, 4,12, 4, 4, 4, 4, 4, 4, 4,12
        db 12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12
        db  4, 4, 4,12, 4, 4, 4, 4, 4, 4, 4,12, 4, 4, 4, 4
        db  4, 4, 4,12, 4, 4, 4, 4, 4, 4, 4,12, 4, 4, 4, 4
        db  4, 4, 4,12, 4, 4, 4, 4, 4, 4, 4,12, 4, 4, 4, 4
        db 12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12
        ; tile 55: Scenery (no collision)
        db  1, 1, 1, 1, 4, 4, 4,12, 1, 1, 1, 1, 4, 4, 4,12
        db  1, 1, 1, 1, 4, 4, 4,12, 1, 1, 1, 1, 4, 4, 4,12
        db  1, 1, 1, 1, 4, 4, 4,12, 1, 1, 1, 1, 4, 4, 4,12
        db  1, 1, 1, 1,12,12,12,12, 1, 1, 1, 1,12,12,12,12
        db  4, 4, 4,12, 4, 4, 4, 4, 4, 4, 4,12, 4, 4, 4, 4
        db  4, 4, 4,12, 4, 4, 4, 4, 4, 4, 4,12, 4, 4, 4, 4
        db  4, 4, 4,12, 4, 4, 4, 4, 4, 4, 4,12, 4, 4, 4, 4
        db 12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12
        db  4, 4, 4, 4, 4, 4, 4,12, 4, 4, 4, 4, 4, 0, 0, 0
        db  4, 4, 4, 4, 4, 4, 4,12, 4, 4, 4, 4, 0, 0, 0, 0
        db  4, 4, 4, 4, 4, 4, 4,12, 4, 4, 4, 4, 0, 0, 0, 0
        db 12,12,12,12,12,12,12,12,12,12,12,12, 0, 0, 0, 0
        db  4, 4, 4,12, 4, 4, 4, 4, 4, 4, 4,12, 0, 0, 0, 0
        db  4, 4, 4,12, 4, 4, 4, 4, 4, 4, 4,12, 0, 0, 0, 0
        db  4, 4, 4,12, 4, 4, 4, 4, 4, 4, 4,12, 0, 0, 0, 0
        db 12,12,12,12,12,12,12,12,12,12,12,12, 0, 0, 0, 0
        ; tile 56: Scenery (no collision)
        db  4, 4, 4, 4, 4, 4, 4,12, 4, 4, 4, 4, 4, 4, 4,12
        db  4, 4, 4, 4, 4, 4, 4,12, 4, 4, 4, 4, 4, 4, 4,12
        db  4, 4, 4, 4, 4, 4, 4,12, 4, 4, 4, 4, 4, 4, 4,12
        db 12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12
        db  4, 4, 4,12, 4, 4, 4, 4, 4, 4, 4,12, 4, 4, 4, 4
        db  4, 4, 4,12, 4, 4, 4, 4, 4, 4, 4,12, 4, 4, 4, 4
        db  4, 4, 4,12, 4, 4, 4, 4, 4, 4, 4,12, 4, 4, 4, 4
        db 12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12
        db  0, 0, 0, 4, 4, 4, 4,12, 4, 4, 4, 4, 4, 4, 4,12
        db  0, 0, 0, 0, 4, 4, 4,12, 4, 4, 4, 4, 4, 4, 4,12
        db  0, 0, 0, 0, 4, 4, 4,12, 4, 4, 4, 4, 4, 4, 4,12
        db  0, 0, 0, 0,12,12,12,12,12,12,12,12,12,12,12,12
        db  0, 0, 0, 0, 4, 4, 4, 4, 4, 4, 4,12, 4, 4, 4, 4
        db  0, 0, 0, 0, 4, 4, 4, 4, 4, 4, 4,12, 4, 4, 4, 4
        db  0, 0, 0, 0, 4, 4, 4, 4, 4, 4, 4,12, 4, 4, 4, 4
        db  0, 0, 0, 0,12,12,12,12,12,12,12,12,12,12,12,12
        ; tile 57: Scenery (no collision)
        db  4, 4, 4, 4, 4, 4, 4,12, 4, 4, 4, 4, 4, 4, 4,12
        db  4, 4, 4, 4, 4, 4, 4,12, 4, 4, 4, 4, 4, 4, 4,12
        db  4, 4, 4, 4, 4, 4, 4,12, 4, 4, 4, 4, 4, 4, 4,12
        db 12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12
        db  4, 4, 4,12, 4, 4, 4, 4, 4, 4, 4,12, 4, 4, 4, 4
        db  4, 4, 4,12, 4, 4, 4, 4, 4, 4, 4,12, 4, 4, 4, 4
        db  4, 4, 4,12, 4, 4, 4, 4, 4, 4, 4,12, 4, 4, 4, 4
        db 12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12
        db  4, 4, 4, 4, 4, 4, 4,12, 4, 4, 4, 4, 4, 4, 4,12
        db  4, 4, 4, 4, 4, 4, 4,12, 4, 4, 4, 4, 4, 4, 4,12
        db  4, 4, 4, 4, 4, 4, 4,12, 4, 4, 4, 4, 4, 4, 4,12
        db 12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12
        db  4, 4, 4,12, 4, 4, 4, 4, 4, 4, 4,12, 4, 4, 4, 4
        db  4, 4, 4,12, 4, 4, 4, 4, 4, 4, 4,12, 4, 4, 4, 4
        db  4, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 4
        db  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
        ; tile 58: Scenery (no collision)
        db  4, 4, 4, 4, 4, 4, 4,12, 4, 4, 4, 4, 4, 4, 4,12
        db  4, 4, 4, 4, 4, 4, 4,12, 4, 4, 4, 4, 4, 4, 4,12
        db  4, 4, 4, 4, 4, 4, 4,12, 4, 4, 4, 4, 4, 4, 4,12
        db 12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12
        db  4, 4, 4,12, 4, 4, 4, 4, 4, 4, 4,12, 4, 4, 4, 4
        db  4, 4, 4,12, 4, 4, 4, 4, 4, 4, 4,12, 4, 4, 4, 4
        db  4, 4, 4,12, 4, 4, 4, 4, 4, 4, 4,12, 4, 4, 4, 4
        db 12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12
        db  4, 4, 4, 4, 4, 4, 4,12, 4, 4, 4, 4, 4, 0, 0, 0
        db  4, 4, 4, 4, 4, 4, 4,12, 4, 4, 4, 4, 0, 0, 0, 0
        db  4, 4, 4, 4, 4, 4, 4,12, 4, 4, 4, 4, 0, 0, 0, 0
        db 12,12,12,12,12,12,12,12,12,12,12,12, 0, 0, 0, 0
        db  4, 4, 4,12, 4, 4, 4, 4, 4, 4, 4,12, 0, 0, 0, 0
        db  4, 4, 4,12, 4, 4, 4, 4, 4, 4, 4,12, 0, 0, 0, 0
        db  4, 4, 4,12, 4, 4, 4, 4, 4, 4, 4,12, 0, 0, 0, 0
        db 12,12,12,12,12,12,12,12,12,12,12,12, 0, 0, 0, 0
        ; tile 59: Scenery (no collision)
        db  1, 1, 1, 1, 4, 4, 4,12, 1, 1, 1, 1, 4, 4, 4,12
        db  1, 1, 1, 1, 4, 4, 4,12, 1, 1, 1, 1, 4, 4, 4,12
        db  1, 1, 1, 1, 4, 4, 4,12, 1, 1, 1, 1, 4, 4, 4,12
        db  1, 1, 1, 1,12,12,12,12, 1, 1, 1, 1,12,12,12,12
        db  4, 4, 4,12, 4, 4, 4, 4, 4, 4, 4,12, 4, 4, 4, 4
        db  4, 4, 4,12, 4, 4, 4, 4, 4, 4, 4,12, 4, 4, 4, 4
        db  4, 4, 4,12, 4, 4, 4, 4, 4, 4, 4,12, 4, 4, 4, 4
        db 12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12
        db  0, 0, 0, 4, 4, 4, 4,12, 4, 4, 4, 4, 4, 4, 4,12
        db  0, 0, 0, 0, 4, 4, 4,12, 4, 4, 4, 4, 4, 4, 4,12
        db  0, 0, 0, 0, 4, 4, 4,12, 4, 4, 4, 4, 4, 4, 4,12
        db  0, 0, 0, 0,12,12,12,12,12,12,12,12,12,12,12,12
        db  0, 0, 0, 0, 4, 4, 4, 4, 4, 4, 4,12, 4, 4, 4, 4
        db  0, 0, 0, 0, 4, 4, 4, 4, 4, 4, 4,12, 4, 4, 4, 4
        db  0, 0, 0, 0, 4, 4, 4, 4, 4, 4, 4,12, 4, 4, 4, 4
        db  0, 0, 0, 0,12,12,12,12,12,12,12,12,12,12,12,12
        ; tile 60: Scenery (no collision)
        db  4, 4, 4, 4, 4, 4, 4,12, 4, 4, 4, 4, 0, 0, 0, 0
        db  4, 4, 4, 4, 4, 4, 4,12, 4, 4, 4, 4, 0, 0, 0, 0
        db  4, 4, 4, 4, 4, 4, 4,12, 4, 4, 4, 4, 0, 0, 0, 0
        db 12,12,12,12,12,12,12,12,12,12,12,12, 0, 0, 0, 0
        db  4, 4, 4,12, 4, 4, 4, 4, 4, 4, 4,12, 4, 4, 4, 4
        db  4, 4, 4,12, 4, 4, 4, 4, 4, 4, 4,12, 4, 4, 4, 4
        db  4, 4, 4,12, 4, 4, 4, 4, 4, 4, 4,12, 4, 4, 4, 4
        db 12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12
        db  4, 4, 4, 4, 4, 4, 4,12, 4, 4, 4, 4, 4, 4, 4,12
        db  4, 4, 4, 4, 4, 4, 4,12, 4, 4, 4, 4, 4, 4, 4,12
        db  4, 4, 4, 4, 4, 4, 4,12, 4, 4, 4, 4, 4, 4, 4,12
        db 12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12
        db  4, 4, 4,12, 4, 4, 4, 4, 4, 4, 4,12, 4, 4, 4, 4
        db  4, 4, 4,12, 4, 4, 4, 4, 4, 4, 4,12, 4, 4, 4, 4
        db  4, 4, 4,12, 4, 4, 4, 4, 4, 4, 4,12, 4, 4, 4, 4
        db 12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12
        ; tile 61: Scenery (no collision)
        db  0, 0, 0, 0, 4, 4, 4,12, 4, 4, 4, 4, 4, 4, 4,12
        db  0, 0, 0, 0, 4, 4, 4,12, 4, 4, 4, 4, 4, 4, 4,12
        db  0, 0, 0, 0, 4, 4, 4,12, 4, 4, 4, 4, 4, 4, 4,12
        db  0, 0, 0, 0,12,12,12,12,12,12,12,12,12,12,12,12
        db  4, 4, 4,12, 4, 4, 4, 4, 4, 4, 4,12, 4, 4, 4, 4
        db  4, 4, 4,12, 4, 4, 4, 4, 4, 4, 4,12, 4, 4, 4, 4
        db  4, 4, 4,12, 4, 4, 4, 4, 4, 4, 4,12, 4, 4, 4, 4
        db 12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12
        db  4, 4, 4, 4, 4, 4, 4,12, 4, 4, 4, 4, 4, 4, 4,12
        db  4, 4, 4, 4, 4, 4, 4,12, 4, 4, 4, 4, 4, 4, 4,12
        db  4, 4, 4, 4, 4, 4, 4,12, 4, 4, 4, 4, 4, 4, 4,12
        db 12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12
        db  4, 4, 4,12, 4, 4, 4, 4, 4, 4, 4,12, 4, 4, 4, 4
        db  4, 4, 4,12, 4, 4, 4, 4, 4, 4, 4,12, 4, 4, 4, 4
        db  4, 4, 4,12, 4, 4, 4, 4, 4, 4, 4,12, 4, 4, 4, 4
        db 12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12
        ; tile 62: Scenery (no collision)
        db  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
        db  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
        db  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
        db  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
        db  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
        db  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
        db  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
        db  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
        db  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
        db  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
        db  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
        db  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
        db  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
        db  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
        db  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
        db  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
        ; tile 63: ? block, orange blink picture
        db 12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12
        db 12,11,11,11,11,11,11,11,11,11,11,11,11,11,11,12
        db 12,11,12,16,16,16,16,16,16,16,16,16,16,12,16,12
        db 12,11,16,16,16,16,16,16,16,16,16,16,16,16,16,12
        db 12,11,16,16,16,16, 9, 9, 9, 9,16,16,16,16,16,12
        db 12,11,16,16,16, 9, 9,16,16, 9, 9,16,16,16,16,12
        db 12,11,16,16,16,16,16,16,16, 9, 9,16,16,16,16,12
        db 12,11,16,16,16,16,16,16, 9, 9,16,16,16,16,16,12
        db 12,11,16,16,16,16,16, 9, 9,16,16,16,16,16,16,12
        db 12,11,16,16,16,16,16, 9, 9,16,16,16,16,16,16,12
        db 12,11,16,16,16,16,16,16,16,16,16,16,16,16,16,12
        db 12,11,16,16,16,16,16, 9, 9,16,16,16,16,16,16,12
        db 12,11,16,16,16,16,16,16,16,16,16,16,16,16,16,12
        db 12,11,12,16,16,16,16,16,16,16,16,16,16,12,16,12
        db 12,11,16,16,16,16,16,16,16,16,16,16,16,16,16,12
        db 12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12

; ---- Level map: 192 columns x 12 rows, one byte per tile ----
; Row 0 is the HUD strip. Rows 10-11 are ground; Mario stands on row 9. Codes 14+ = scenery.
level_original:
        ; row 0, columns 0-31
        db  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
        ; row 0, columns 32-63
        db  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
        ; row 0, columns 64-95
        db  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
        ; row 0, columns 96-127
        db  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
        ; row 0, columns 128-159
        db  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
        ; row 0, columns 160-191
        db  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
        ; row 1, columns 0-31
        db  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,18,19,20, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
        ; row 1, columns 32-63
        db  0, 0, 0, 0, 0, 0,14,15, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,14,15, 0, 0
        ; row 1, columns 64-95
        db  0, 0, 0, 0,23,24,25,26, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,14
        ; row 1, columns 96-127
        db 15, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,23,24,25,26, 0, 0, 0, 0, 0, 0, 0,14,15, 0, 0
        ; row 1, columns 128-159
        db  0, 0, 0, 0, 0, 0, 0,18,19,20, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,18,19,20, 0, 0, 0
        ; row 1, columns 160-191
        db  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,14,15, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
        ; row 2, columns 0-31
        db  0, 0, 0, 0,14,15, 0, 0, 0, 0, 0, 0, 0, 0,16,21,22, 0, 0, 0, 0, 0, 0, 0, 0, 0,23,24,25,26, 0, 0
        ; row 2, columns 32-63
        db  0, 0, 0, 0, 0, 0,16,17, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,16,17, 0, 0
        ; row 2, columns 64-95
        db  0, 0, 0, 0,16,27,27,17, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,18,19,20, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,16
        ; row 2, columns 96-127
        db 17, 0, 0, 0, 0, 0, 0, 0, 0,18,19,20, 0, 0, 0, 0, 0,16,27,27,17, 0, 0, 0, 0, 0, 0, 0,16,17, 0, 0
        ; row 2, columns 128-159
        db  0, 0, 0, 0, 0, 0, 0,16,21,22, 0, 0, 0, 0, 0, 0, 0, 0,14,15, 0, 0, 0, 0, 0, 0,16,21,22, 0, 0, 0
        ; row 2, columns 160-191
        db  0, 0, 0, 0, 0,23,24,25,26, 0, 0, 0, 0,16,17, 0, 0, 0,10, 0, 0,13, 0, 0, 0, 0,18,19,20, 0, 0, 0
        ; row 3, columns 0-31
        db  0, 0, 0, 0,16,17, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,16,27,27,17, 0, 0
        ; row 3, columns 32-63
        db  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,18,19,20, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
        ; row 3, columns 64-95
        db  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,16,21,22, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
        ; row 3, columns 96-127
        db  0, 0, 0, 0, 0, 0, 0, 0, 0,16,21,22, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
        ; row 3, columns 128-159
        db  3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,16,17, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
        ; row 3, columns 160-191
        db  0, 0, 0, 0, 0,16,27,27,17, 0, 0, 0, 0, 0, 0, 0, 0,10,10, 0, 0,12, 0, 0, 0, 0,16,21,22, 0, 0, 0
        ; row 4, columns 0-31
        db  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
        ; row 4, columns 32-63
        db  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,16,21,22, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
        ; row 4, columns 64-95
        db  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
        ; row 4, columns 96-127
        db  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
        ; row 4, columns 128-159
        db  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,10, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
        ; row 4, columns 160-191
        db  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,10,10,10, 0, 0,12, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
        ; row 5, columns 0-31
        db  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
        ; row 5, columns 32-63
        db  0,11,11,11, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
        ; row 5, columns 64-95
        db  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,11,11, 0, 0, 0, 0, 0, 0
        ; row 5, columns 96-127
        db  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
        ; row 5, columns 128-159
        db  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,10,10, 0, 0, 0, 0, 0,11,11, 0, 0, 0, 0, 0, 0, 0, 0, 0
        ; row 5, columns 160-191
        db  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,10,10,10,10, 0, 0,12, 0, 0, 0, 0, 0,49, 0, 0, 0, 0
        ; row 6, columns 0-31
        db  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 4, 2, 3, 2, 0, 0, 0, 3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
        ; row 6, columns 32-63
        db  2, 2, 3, 2, 2, 0, 0, 0, 4, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
        ; row 6, columns 64-95
        db  0, 0, 0, 0, 0, 0, 0, 0, 2, 3, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,10, 0, 0,10, 0, 0, 0, 0, 0
        ; row 6, columns 96-127
        db  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 3, 2
        ; row 6, columns 128-159
        db  4, 2, 3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,10,10,10, 0, 0, 0, 0, 2, 2, 2, 2, 0, 2, 3, 2, 0, 0, 0, 0
        ; row 6, columns 160-191
        db  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,10,10,10,10,10, 0, 0,12, 0, 0, 0, 0,50,51,52, 0, 0, 0
        ; row 7, columns 0-31
        db  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 6, 7, 0, 0
        ; row 7, columns 32-63
        db  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,11,11,11, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 6, 7, 0, 0, 0, 0
        ; row 7, columns 64-95
        db  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,10,10, 0, 0,10,10, 0, 0, 0, 0
        ; row 7, columns 96-127
        db  0, 0, 0, 0, 0, 0, 0, 0, 0, 6, 7, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,11,11,11, 0, 0, 0, 0, 0, 0, 0
        ; row 7, columns 128-159
        db  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,10,10,10,10,11,11,11, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
        ; row 7, columns 160-191
        db  6, 7, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,10,10,10,10,10,10, 0, 0,12, 0, 0, 0, 0,53,51,54, 0, 0, 0
        ; row 8, columns 0-31
        db  0, 0, 0, 0, 0,11,11,11,28,29,30,31,32, 0, 0, 0, 0, 6, 7, 0, 0, 0, 0, 0,11,11, 0, 0, 8, 9, 0, 0
        ; row 8, columns 32-63
        db  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,28,29,30,31,32, 6, 7, 0, 0, 0, 0, 8, 9, 0, 0, 0, 0
        ; row 8, columns 64-95
        db 11,11, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,10,10,10, 0, 0,10,10,10, 0,28,29
        ; row 8, columns 96-127
        db 30,31,32, 0, 6, 7, 0, 0, 0, 8, 9, 0, 0, 0, 0, 6, 7, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
        ; row 8, columns 128-159
        db  0, 0, 0, 0,28,29,30,31,32, 0, 0,10,10,10,10,10, 0, 0, 0, 0, 0, 0,28,29,30,31,32, 0, 0, 0, 0, 0
        ; row 8, columns 160-191
        db  8, 9, 0, 0, 0, 0,11,11, 0, 0, 0, 0,10,10,10,10,10,10,10, 0, 0,12, 0, 0, 0,55,56,57,58,59, 0, 0
        ; row 9, columns 0-31
        db  0,43,44,45, 0, 0, 0, 0,33,34,35,36,37, 0, 0, 0, 0, 8, 9, 0, 0, 0,41,42, 0, 0, 0, 0, 8, 9, 0, 0
        ; row 9, columns 32-63
        db  0, 0, 0, 0,38,39,40, 0,43,46,47,48, 0, 0, 0,33,34,35,36,37, 8, 9, 0, 0, 0, 0, 8, 9, 0,43,44,45
        ; row 9, columns 64-95
        db  0, 0, 0, 0,38,39,40, 0, 0, 0, 0, 0, 0,41,42, 0, 0, 0, 0, 0,10,10,10,10, 0, 0,10,10,10,10,33,34
        ; row 9, columns 96-127
        db 35,36,37, 0, 8, 9, 0, 0, 0, 8, 9, 0,43,44,45, 8, 9, 0, 0, 0, 0, 0, 0, 0, 0, 0,38,39,40, 0,43,46
        ; row 9, columns 128-159
        db 47,48,41,42,33,34,35,36,37, 0,10,10,10,10,10,10, 0, 0, 0, 0, 0, 0,33,34,35,36,37,43,44,45, 0, 0
        ; row 9, columns 160-191
        db  8, 9, 0, 0, 0, 0, 0, 0, 0, 0, 0,10,10,10,10,10,10,10,10, 0, 0,10, 0,41,42,60,61,62,60,61, 0, 0
        ; row 10, columns 0-31
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 1, 1, 1, 1, 1, 1
        ; row 10, columns 32-63
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        ; row 10, columns 64-95
        db  0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 1, 1, 1, 1, 1, 1
        ; row 10, columns 96-127
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 1, 1, 1, 1, 1, 1, 1
        ; row 10, columns 128-159
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        ; row 10, columns 160-191
        db  1, 1, 1, 1, 1, 1, 0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        ; row 11, columns 0-31
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 1, 1, 1, 1, 1, 1
        ; row 11, columns 32-63
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        ; row 11, columns 64-95
        db  0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 1, 1, 1, 1, 1, 1
        ; row 11, columns 96-127
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 1, 1, 1, 1, 1, 1, 1
        ; row 11, columns 128-159
        db  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        ; row 11, columns 160-191
        db  1, 1, 1, 1, 1, 1, 0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1


; ---- Sound (Module 16): everything the timer interrupt and the game share ----
snd_on          db 1            ; 1 = sound on (M switches it)
snd_hold        db 0            ; 1 = paused: nothing sounds, nothing advances
snd_msg         db 0            ; frames left for the SOUND ON / SOUND OFF message
snd_last        dw 0            ; the timer divisor the speaker plays now (0 = silent)
mus_mode        db 0            ; 0 none, 1 loops (background), 2 and 3 play once
mus_start       dw 0            ; first note of the tune (the loop goes back here)
mus_ptr         dw 0            ; next note
mus_timer       db 0            ; ticks left of the current note
mus_cur         dw 0            ; divisor of the current music note (0 = rest)
sfx_ptr         dw 0            ; next sound-effect note (0 = no effect playing)
sfx_timer       db 0
sfx_cur         dw 0
sfx_prio        db 0            ; priority of the effect playing now
txt_sound_on    db 'SOUND ON', 0
txt_sound_off   db 'SOUND OFF', 0
txt_snd_on      db 'SOUND: ON - PRESS M', 0
txt_snd_off     db 'SOUND: OFF - PRESS M', 0

%macro NOTE 2                   ; divisor of the timer chip (0 = rest), length in ticks (1/30 s)
        dw      %1
        db      %2
%endmacro

; background music: 16 bars (about 17 seconds), loops forever (our own tune, C major / A minor)
mus_background:
        NOTE     2280,  3       ; C5
        NOTE        0,  1       ; -
        NOTE     1810,  3       ; E5
        NOTE        0,  1       ; -
        NOTE     1522,  3       ; G5
        NOTE        0,  1       ; -
        NOTE     1810,  3       ; E5
        NOTE        0,  1       ; -
        NOTE     2280,  3       ; C5
        NOTE        0,  1       ; -
        NOTE     1810,  3       ; E5
        NOTE        0,  1       ; -
        NOTE     1522,  3       ; G5
        NOTE        0,  1       ; -
        NOTE        0,  4       ; rest
        NOTE     2712,  3       ; A4
        NOTE        0,  1       ; -
        NOTE     2280,  3       ; C5
        NOTE        0,  1       ; -
        NOTE     1810,  3       ; E5
        NOTE        0,  1       ; -
        NOTE     2280,  3       ; C5
        NOTE        0,  1       ; -
        NOTE     2712,  3       ; A4
        NOTE        0,  1       ; -
        NOTE     2280,  3       ; C5
        NOTE        0,  1       ; -
        NOTE     1810,  3       ; E5
        NOTE        0,  1       ; -
        NOTE        0,  4       ; rest
        NOTE     3417,  3       ; F4
        NOTE        0,  1       ; -
        NOTE     2712,  3       ; A4
        NOTE        0,  1       ; -
        NOTE     2280,  3       ; C5
        NOTE        0,  1       ; -
        NOTE     2712,  3       ; A4
        NOTE        0,  1       ; -
        NOTE     3417,  3       ; F4
        NOTE        0,  1       ; -
        NOTE     2712,  3       ; A4
        NOTE        0,  1       ; -
        NOTE     2280,  3       ; C5
        NOTE        0,  1       ; -
        NOTE        0,  4       ; rest
        NOTE     3044,  3       ; G4
        NOTE        0,  1       ; -
        NOTE     2416,  3       ; B4
        NOTE        0,  1       ; -
        NOTE     2032,  3       ; D5
        NOTE        0,  1       ; -
        NOTE     2416,  3       ; B4
        NOTE        0,  1       ; -
        NOTE     3044,  3       ; G4
        NOTE        0,  1       ; -
        NOTE     2416,  3       ; B4
        NOTE        0,  1       ; -
        NOTE     2032,  3       ; D5
        NOTE        0,  1       ; -
        NOTE        0,  4       ; rest
        NOTE     1810,  3       ; E5
        NOTE        0,  1       ; -
        NOTE        0,  4       ; rest
        NOTE     1810,  3       ; E5
        NOTE        0,  1       ; -
        NOTE     2032,  3       ; D5
        NOTE        0,  1       ; -
        NOTE     2280,  3       ; C5
        NOTE        0,  1       ; -
        NOTE        0,  4       ; rest
        NOTE     2032,  3       ; D5
        NOTE        0,  1       ; -
        NOTE     1810,  3       ; E5
        NOTE        0,  1       ; -
        NOTE     1522,  3       ; G5
        NOTE        0,  1       ; -
        NOTE        0,  4       ; rest
        NOTE     1522,  3       ; G5
        NOTE        0,  1       ; -
        NOTE     1708,  3       ; F5
        NOTE        0,  1       ; -
        NOTE     1810,  3       ; E5
        NOTE        0,  1       ; -
        NOTE        0,  4       ; rest
        NOTE     1708,  3       ; F5
        NOTE        0,  1       ; -
        NOTE     1522,  3       ; G5
        NOTE        0,  1       ; -
        NOTE     1356,  3       ; A5
        NOTE        0,  1       ; -
        NOTE     1522,  3       ; G5
        NOTE        0,  1       ; -
        NOTE     1708,  3       ; F5
        NOTE        0,  1       ; -
        NOTE     1810,  3       ; E5
        NOTE        0,  1       ; -
        NOTE     2032,  3       ; D5
        NOTE        0,  1       ; -
        NOTE     1810,  3       ; E5
        NOTE        0,  1       ; -
        NOTE     2032,  3       ; D5
        NOTE        0,  1       ; -
        NOTE     2280,  3       ; C5
        NOTE        0,  1       ; -
        NOTE     2032,  3       ; D5
        NOTE        0,  1       ; -
        NOTE        0,  4       ; rest
        NOTE     3044,  3       ; G4
        NOTE        0,  1       ; -
        NOTE        0,  4       ; rest
        NOTE     2416,  3       ; B4
        NOTE        0,  1       ; -
        NOTE     2032,  3       ; D5
        NOTE        0,  1       ; -
        NOTE     2280,  3       ; C5
        NOTE        0,  1       ; -
        NOTE        0,  4       ; rest
        ; ---- second half: 8 more bars, softer and slower (quarter notes), so the whole tune is 16 bars = about 17 s ----
        ; bar 9
        NOTE    1810,  6       ; E5
        NOTE        0,  2       ; -
        NOTE    2032,  6       ; D5
        NOTE        0,  2       ; -
        NOTE    2280,  6       ; C5
        NOTE        0,  2       ; -
        NOTE    2712,  6       ; A4
        NOTE        0,  2       ; -
        ; bar 10
        NOTE    2712,  6       ; A4
        NOTE        0,  2       ; -
        NOTE    2280,  6       ; C5
        NOTE        0,  2       ; -
        NOTE    1708,  6       ; F5
        NOTE        0,  2       ; -
        NOTE    1810,  6       ; E5
        NOTE        0,  2       ; -
        ; bar 11
        NOTE    1522,  6       ; G5
        NOTE        0,  2       ; -
        NOTE    1810,  6       ; E5
        NOTE        0,  2       ; -
        NOTE    2280,  6       ; C5
        NOTE        0,  2       ; -
        NOTE    1810,  6       ; E5
        NOTE        0,  2       ; -
        ; bar 12
        NOTE    2032,  6       ; D5
        NOTE        0,  2       ; -
        NOTE    2416,  6       ; B4
        NOTE        0,  2       ; -
        NOTE    3044,  6       ; G4
        NOTE        0,  2       ; -
        NOTE    2032,  6       ; D5
        NOTE        0,  2       ; -
        ; bar 13
        NOTE    1810,  6       ; E5
        NOTE        0,  2       ; -
        NOTE    2280,  6       ; C5
        NOTE        0,  2       ; -
        NOTE    2712,  6       ; A4
        NOTE        0,  2       ; -
        NOTE    2280,  6       ; C5
        NOTE        0,  2       ; -
        ; bar 14
        NOTE    1708,  6       ; F5
        NOTE        0,  2       ; -
        NOTE    1356,  6       ; A5
        NOTE        0,  2       ; -
        NOTE    1708,  6       ; F5
        NOTE        0,  2       ; -
        NOTE    2280,  6       ; C5
        NOTE        0,  2       ; -
        ; bar 15
        NOTE    2032,  6       ; D5
        NOTE        0,  2       ; -
        NOTE    3044,  6       ; G4
        NOTE        0,  2       ; -
        NOTE    2416,  6       ; B4
        NOTE        0,  2       ; -
        NOTE    2032,  6       ; D5
        NOTE        0,  2       ; -
        ; bar 16
        NOTE    2280,  6       ; C5
        NOTE        0,  2       ; -
        NOTE    1810,  6       ; E5
        NOTE        0,  2       ; -
        NOTE    2280, 14       ; C5 (long)
        NOTE        0,  2       ; -
        dw      0FFFFh                  ; end of the tune

; victory tune: plays once when Mario takes the flag
mus_victory:
        NOTE     2280,  3       ; C5
        NOTE     1810,  3       ; E5
        NOTE     1522,  3       ; G5
        NOTE     1140,  3       ; C6
        NOTE      905,  3       ; E6
        NOTE      761,  3       ; G6
        NOTE        0,  1       ; R
        NOTE      905,  3       ; E6
        NOTE      761,  3       ; G6
        NOTE      570, 14       ; C7
        NOTE        0,  4       ; R
        NOTE     1140,  3       ; C6
        NOTE     1522,  3       ; G5
        NOTE      905,  3       ; E6
        NOTE     1140,  3       ; C6
        NOTE      761,  3       ; G6
        NOTE      905,  3       ; E6
        NOTE      570, 18       ; C7
        dw      0FFFFh                  ; end of the tune

; death tune: plays once when Mario dies (sad, going down)
mus_death:
        NOTE     1522,  4       ; G5
        NOTE     1612,  4       ; F#5
        NOTE     1708,  4       ; F5
        NOTE     1810,  4       ; E5
        NOTE     1918,  4       ; D#5
        NOTE     2032,  4       ; D5
        NOTE     2152,  4       ; C#5
        NOTE     2280,  5       ; C5
        NOTE        0,  3       ; R
        NOTE     3044,  6       ; G4
        NOTE     3620,  6       ; E4
        NOTE     4561, 16       ; C4
        dw      0FFFFh                  ; end of the tune

; sound effect - jump: five quick rising notes
sfx_jump:
        NOTE     3620,  1       ; E4
        NOTE     3044,  1       ; G4
        NOTE     2560,  1       ; A#4
        NOTE     2152,  1       ; C#5
        NOTE     1810,  1       ; E5
        dw      0FFFFh                  ; end of the tune

; sound effect - coin: two bright notes
sfx_coin:
        NOTE     1208,  2       ; B5
        NOTE      905,  7       ; E6
        dw      0FFFFh                  ; end of the tune

; sound effect - stomp: a short falling squeak
sfx_stomp:
        NOTE     1522,  1       ; G5
        NOTE     2032,  1       ; D5
        NOTE     2560,  1       ; A#4
        NOTE     4063,  1       ; D4
        NOTE     5424,  2       ; A3
        dw      0FFFFh                  ; end of the tune

; sound effect - power-up: rising run
sfx_power:
        NOTE     2280,  1       ; C5
        NOTE     1810,  1       ; E5
        NOTE     1522,  1       ; G5
        NOTE     1140,  1       ; C6
        NOTE      905,  1       ; E6
        NOTE      761,  1       ; G6
        NOTE      570,  3       ; C7
        dw      0FFFFh                  ; end of the tune


; ---- Working copy of the map: blocks hit and coins taken change this one ----
level_working   times MAP_SIZE db 0
q_picture       db T_QBLOCK_COIN        ; tile shown by every ? block this frame (yellow or orange)

; ---- Sprite bitmaps: 16 bytes per row, 16 rows (small) or 32 rows (super).
; ---- Colour index 0 is transparent and is never drawn. All sprites face right.
spr_hero_stand:                       ; hero standing (16x16)
        db  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
        db  0, 0, 0, 0, 0,12,12,12,12,12, 0, 0, 0, 0, 0, 0
        db  0, 0, 0, 0,12,15,15,15,15,15,12, 0, 0, 0, 0, 0
        db  0, 0, 0,12,15,15,15,15,15,15,15,12,12, 0, 0, 0
        db  0, 0, 0,12,15,15,15,15,15,12,12,12,12,12, 0, 0
        db  0, 0, 0,12,12, 7, 7, 7, 7, 7, 7,12, 0, 0, 0, 0
        db  0, 0, 6, 6,12, 7, 7, 7, 9,12, 7, 7,12, 0, 0, 0
        db  0, 0, 6, 6,12, 7, 7, 7, 7, 7, 7, 7,12, 0, 0, 0
        db  0, 6, 6, 0,12, 7, 7,12,12,12, 7,12, 0, 0, 0, 0
        db  0, 0, 6, 6,12,12,10,10,10,10,12,12, 0, 0, 0, 0
        db  0, 0, 0, 0, 0,12,10,10,10,10,10,10,12, 0, 0, 0
        db  0, 0, 0, 0, 7,12,10,10,10,10,10,10,12, 7, 0, 0
        db  0, 0, 0, 0, 7,12,10,10,10,10,10,10,12, 7, 0, 0
        db  0, 0, 0, 0, 0,12,14,14,14,14,14,14,12, 0, 0, 0
        db  0, 0, 0, 0, 0,12,14,14,12,12,14,14,12, 0, 0, 0
        db  0, 0, 0, 0,12, 3, 3,12, 0, 0,12, 3, 3,12, 0, 0
spr_hero_run:                       ; hero running (16x16)
        db  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
        db  0, 0, 0, 0, 0,12,12,12,12,12, 0, 0, 0, 0, 0, 0
        db  0, 0, 0, 0,12,15,15,15,15,15,12, 0, 0, 0, 0, 0
        db  0, 0, 0,12,15,15,15,15,15,15,15,12,12, 0, 0, 0
        db  0, 0, 0,12,15,15,15,15,15,12,12,12,12,12, 0, 0
        db  0, 0, 0,12,12, 7, 7, 7, 7, 7, 7,12, 0, 0, 0, 0
        db  0, 0, 6, 6,12, 7, 7, 7, 9,12, 7, 7,12, 0, 0, 0
        db  0, 0, 6, 6,12, 7, 7, 7, 7, 7, 7, 7,12, 0, 0, 0
        db  0, 6, 6, 0,12, 7, 7,12,12,12, 7,12, 0, 0, 0, 0
        db  0, 0, 6, 6,12,12,10,10,10,10,12,12, 0, 0, 0, 0
        db  0, 0, 0, 0, 0,12,10,10,10,10,10,10,12, 0, 0, 0
        db  0, 0, 0, 7, 7,12,10,10,10,10,10,10,12, 0, 0, 0
        db  0, 0, 0, 0, 0,12,10,10,10,10,10,10,12, 7, 0, 0
        db  0, 0, 0, 0, 0,12,14,14,14,14,14,14,12, 0, 0, 0
        db  0, 0, 0, 0,12,14,14,12, 0,12,14,14,12, 0, 0, 0
        db  0, 0, 0,12, 3, 3,12, 0, 0, 0,12, 3, 3,12, 0, 0
spr_hero_jump:                       ; hero jumping (16x16)
        db  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
        db  0, 0, 0, 0, 0,12,12,12,12,12, 0, 0, 0, 0, 0, 0
        db  0, 0, 0, 0,12,15,15,15,15,15,12, 0, 0, 0, 0, 0
        db  0, 0, 0,12,15,15,15,15,15,15,15,12,12, 0, 0, 0
        db  0, 0, 0,12,15,15,15,15,15,12,12,12,12,12, 0, 0
        db  0, 0, 0,12,12, 7, 7, 7, 7, 7, 7,12, 0, 0, 7, 7
        db  0, 0, 6, 6,12, 7, 7, 7, 9,12, 7, 7,12, 0, 7,12
        db  0, 0, 6, 6,12, 7, 7, 7, 7, 7, 7, 7,12,10,12, 0
        db  0, 6, 6, 0,12, 7, 7,12,12,12, 7,12,10,12, 0, 0
        db  0, 0, 6, 6,12,12,10,10,10,10,12,12,12, 0, 0, 0
        db  0, 0, 0, 0, 0,12,10,10,10,10,10,10,12, 0, 0, 0
        db  0, 0, 0, 0, 7,12,10,10,10,10,10,10,12, 0, 0, 0
        db  0, 0, 0, 0, 7,12,10,10,10,10,10,10,12, 0, 0, 0
        db  0, 0, 0,12,14,14,14,14,14,14,14,14,12, 0, 0, 0
        db  0, 0,12,14,14,14,12, 0, 0,12,14,14,14,12, 0, 0
        db  0, 0,12, 3, 3,12, 0, 0, 0, 0,12, 3, 3,12, 0, 0
spr_walker_a:                       ; walker enemy, walk frame A
        db  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
        db  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
        db  0, 0, 0, 0, 0,12,12,12,12,12,12, 0, 0, 0, 0, 0
        db  0, 0, 0,12,12, 8, 8, 8, 8, 8, 8,12,12, 0, 0, 0
        db  0, 0,12, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8,12, 0, 0
        db  0,12, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8,12, 0
        db  0,12, 8, 8, 9, 9, 8, 8, 8, 8, 9, 9, 8, 8,12, 0
        db  0,12, 8, 8, 9,12, 8, 8, 8, 8,12, 9, 8, 8,12, 0
        db  0,12, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8,12, 0
        db  0,12, 8, 8, 8,12,12,12,12,12,12, 8, 8, 8,12, 0
        db  0, 0,12, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8,12, 0, 0
        db  0, 0, 0,12,12, 8, 8, 8, 8, 8, 8,12,12, 0, 0, 0
        db  0, 0, 0, 0,12,12,12,12,12,12,12,12, 0, 0, 0, 0
        db  0, 0, 0,12, 3, 3,12, 0, 0,12, 3, 3,12, 0, 0, 0
        db  0, 0,12, 3, 3, 3,12, 0, 0,12, 3, 3, 3,12, 0, 0
        db  0, 0,12,12,12,12,12, 0, 0,12,12,12,12,12, 0, 0
spr_walker_b:                       ; walker enemy, walk frame B
        db  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
        db  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
        db  0, 0, 0, 0, 0,12,12,12,12,12,12, 0, 0, 0, 0, 0
        db  0, 0, 0,12,12, 8, 8, 8, 8, 8, 8,12,12, 0, 0, 0
        db  0, 0,12, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8,12, 0, 0
        db  0,12, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8,12, 0
        db  0,12, 8, 8, 9, 9, 8, 8, 8, 8, 9, 9, 8, 8,12, 0
        db  0,12, 8, 8, 9,12, 8, 8, 8, 8,12, 9, 8, 8,12, 0
        db  0,12, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8,12, 0
        db  0,12, 8, 8, 8,12,12,12,12,12,12, 8, 8, 8,12, 0
        db  0, 0,12, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8,12, 0, 0
        db  0, 0, 0,12,12, 8, 8, 8, 8, 8, 8,12,12, 0, 0, 0
        db  0, 0, 0, 0,12,12,12,12,12,12,12,12, 0, 0, 0, 0
        db  0, 0, 0, 0,12, 3, 3,12, 0,12, 3, 3,12, 0, 0, 0
        db  0, 0, 0,12, 3, 3, 3,12, 0,12, 3, 3, 3,12, 0, 0
        db  0, 0, 0,12,12,12,12,12, 0,12,12,12,12,12, 0, 0
spr_walker_flat:                       ; walker enemy, flattened
        db  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
        db  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
        db  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
        db  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
        db  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
        db  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
        db  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
        db  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
        db  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
        db  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
        db  0, 0, 0,12,12,12,12,12,12,12,12,12,12, 0, 0, 0
        db  0,12,12, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8,12,12, 0
        db 12, 8, 8, 9,12, 8, 8, 8, 8, 8, 8,12, 9, 8, 8,12
        db 12, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8,12
        db  0,12,12, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8,12,12, 0
        db  0, 0, 0,12,12,12,12,12,12,12,12,12,12, 0, 0, 0
spr_snail_a:                       ; snail enemy, walk frame A
        db  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
        db  0, 0, 0, 0, 0,12,12,12, 0, 0, 0, 0, 0, 0, 0, 0
        db  0, 0, 0,12,12,11,11,11,12,12, 0, 0, 0, 0, 0, 0
        db  0, 0,12,11,11,11,11,11,11,11,12, 0, 0,12,12, 0
        db  0,12,11,11,11,10,10,10,11,11,11,12,12, 9, 9,12
        db  0,12,11,11,10,10,10,10,10,11,11,12,12, 7,12, 0
        db 12,11,11,10,10, 3, 3, 3,10,10,11,11,12, 7,12, 0
        db 12,11,11,10,10, 3, 3, 3,10,10,11,11,12, 7,12, 0
        db 12,11,11,10,10, 3, 3, 3,10,10,11,11, 7, 7, 7,12
        db  0,12,11,11,10,10,10,10,10,11,11,12, 7, 7, 7,12
        db  0,12,11,11,11,10,10,10,11,11,11,12, 7, 7, 7,12
        db  0,12,12,11,11,11,11,11,11,11,12,12, 7, 7, 7,12
        db 12, 7, 7, 7, 7,11,11,11, 7, 7, 7, 7, 7, 7, 7,12
        db 12, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7,12
        db  0,12,12,12,12,12,12,12,12,12,12,12,12,12,12, 0
        db  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
spr_snail_b:                       ; snail enemy, walk frame B
        db  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
        db  0, 0, 0, 0, 0,12,12,12, 0, 0, 0, 0, 0, 0, 0, 0
        db  0, 0, 0,12,12,11,11,11,12,12, 0, 0, 0,12,12, 0
        db  0, 0,12,11,11,11,11,11,11,11,12, 0,12, 9, 9,12
        db  0,12,11,11,11,10,10,10,11,11,11,12,12, 7,12, 0
        db  0,12,11,11,10,10,10,10,10,11,11,12,12, 7,12, 0
        db 12,11,11,10,10, 3, 3, 3,10,10,11,11,12, 7,12, 0
        db 12,11,11,10,10, 3, 3, 3,10,10,11,11, 7, 7, 7,12
        db 12,11,11,10,10, 3, 3, 3,10,10,11,11, 7, 7, 7,12
        db  0,12,11,11,10,10,10,10,10,11,11,12, 7, 7, 7,12
        db  0,12,11,11,11,10,10,10,11,11,11,12, 7, 7, 7,12
        db  0, 0,12,11,11,11,11,11,11,11,12,12, 7, 7, 7,12
        db  0,12, 7, 7, 7,11,11,11, 7, 7, 7, 7, 7, 7, 7,12
        db  0,12, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7,12
        db  0, 0,12,12,12,12,12,12,12,12,12,12,12,12,12, 0
        db  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
spr_shell:                       ; snail shell
        db  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
        db  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
        db  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
        db  0, 0, 0, 0, 0,12,12,12,12,12,12, 0, 0, 0, 0, 0
        db  0, 0, 0,12,12,11,11,11,11,11,11,12,12, 0, 0, 0
        db  0, 0,12,11,11,11,11,11,11,11,11,11,11,12, 0, 0
        db  0,12,11,11,11,11,10,10,10,10,11,11,11,11,12, 0
        db 12,11,11,11,10,10,10,10,10,10,10,10,11,11,11,12
        db 12,11,11,11,10,10, 3, 3, 3, 3,10,10,11,11,11,12
        db 12,11,11,11,10,10, 3, 3, 3, 3,10,10,11,11,11,12
        db 12,11,11,11,10,10, 3, 3, 3, 3,10,10,11,11,11,12
        db 12,11,11,11,10,10,10,10,10,10,10,10,11,11,11,12
        db  0,12,11,11,11,11,10,10,10,10,11,11,11,11,12, 0
        db  0, 0,12,13,13,13,13,13,13,13,13,13,13,12, 0, 0
        db  0, 0, 0,12,12,11,11,11,11,11,11,12,12, 0, 0, 0
        db  0, 0, 0, 0, 0,12,12,12,12,12,12, 0, 0, 0, 0, 0
spr_mushroom:                       ; power-up mushroom
        db  0, 0, 0, 0, 0, 0, 0, 0,12,12, 0, 0, 0, 0, 0, 0
        db  0, 0, 0, 0, 0,12,12,12, 9, 9,12, 0, 0, 0, 0, 0
        db  0, 0, 0,12,12,14,14,14, 9, 9,14,12,12, 0, 0, 0
        db  0, 0,12,14, 9, 9,14,14,14,14,14,14,14,12, 0, 0
        db  0,12,14,14, 9, 9,14,14,14,14,14, 9, 9,14,12, 0
        db  0,12,14,14,14,14,14,14,14,14,14, 9, 9,14,12, 0
        db 12,14,14,14,14,14,14,14,14,14,14,14,14,14,14,12
        db 12,14,14,14,14,14,14,14,14,14,14,14,14,14,14,12
        db  0,12,12,12, 7, 7, 7, 7, 7, 7, 7, 7,12,12,12, 0
        db  0, 0, 0,12, 7, 7, 7, 7, 7, 7, 7, 7,12, 0, 0, 0
        db  0, 0, 0,12, 7, 7,12, 7, 7,12, 7, 7,12, 0, 0, 0
        db  0, 0, 0,12, 7, 7, 7, 7, 7, 7, 7, 7,12, 0, 0, 0
        db  0, 0, 0,12, 7, 7, 7, 7, 7, 7, 7, 7,12, 0, 0, 0
        db  0, 0, 0,12, 7, 7, 7, 7, 7, 7, 7, 7,12, 0, 0, 0
        db  0, 0, 0, 0,12, 7, 7, 7, 7, 7, 7,12, 0, 0, 0, 0
        db  0, 0, 0, 0, 0,12,12,12,12,12,12, 0, 0, 0, 0, 0
spr_coin:                       ; coin
        db  0, 0, 0, 0, 0, 0, 0,12,12, 0, 0, 0, 0, 0, 0, 0
        db  0, 0, 0, 0, 0, 0,12,11,11,12, 0, 0, 0, 0, 0, 0
        db  0, 0, 0, 0, 0,12,11,11,11,11,12, 0, 0, 0, 0, 0
        db  0, 0, 0, 0,12,11,11,10,11,11,11,12, 0, 0, 0, 0
        db  0, 0, 0, 0,12,11,11,10,11,11,11,12, 0, 0, 0, 0
        db  0, 0, 0, 0,12,11,11,10,11,11,11,12, 0, 0, 0, 0
        db  0, 0, 0,12,11,11,11,10,11,11,11,11,12, 0, 0, 0
        db  0, 0, 0,12,11,11,11,10,11,11,11,11,12, 0, 0, 0
        db  0, 0, 0,12,11,11,11,10,11,11,11,11,12, 0, 0, 0
        db  0, 0, 0,12,11,11,11,10,11,11,11,11,12, 0, 0, 0
        db  0, 0, 0, 0,12,11,11,10,11,11,11,12, 0, 0, 0, 0
        db  0, 0, 0, 0,12,11,11,10,11,11,11,12, 0, 0, 0, 0
        db  0, 0, 0, 0,12,11,11,10,11,11,11,12, 0, 0, 0, 0
        db  0, 0, 0, 0, 0,12,11,11,11,11,12, 0, 0, 0, 0, 0
        db  0, 0, 0, 0, 0, 0,12,11,11,12, 0, 0, 0, 0, 0, 0
        db  0, 0, 0, 0, 0, 0, 0,12,12, 0, 0, 0, 0, 0, 0, 0
spr_super_stand:                       ; super hero standing (16x32)
        db  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
        db  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
        db  0, 0, 0, 0, 0,12,12,12,12,12, 0, 0, 0, 0, 0, 0
        db  0, 0, 0, 0, 0,12,12,12,12,12, 0, 0, 0, 0, 0, 0
        db  0, 0, 0, 0,12,15,15,15,15,15,12, 0, 0, 0, 0, 0
        db  0, 0, 0, 0,12,15,15,15,15,15,12, 0, 0, 0, 0, 0
        db  0, 0, 0,12,15,15,15,15,15,15,15,12,12, 0, 0, 0
        db  0, 0, 0,12,15,15,15,15,15,15,15,12,12, 0, 0, 0
        db  0, 0, 0,12,15,15,15,15,15,12,12,12,12,12, 0, 0
        db  0, 0, 0,12,15,15,15,15,15,12,12,12,12,12, 0, 0
        db  0, 0, 0,12,12, 7, 7, 7, 7, 7, 7,12, 0, 0, 0, 0
        db  0, 0, 0,12,12, 7, 7, 7, 7, 7, 7,12, 0, 0, 0, 0
        db  0, 0, 6, 6,12, 7, 7, 7, 9,12, 7, 7,12, 0, 0, 0
        db  0, 0, 6, 6,12, 7, 7, 7, 9,12, 7, 7,12, 0, 0, 0
        db  0, 0, 6, 6,12, 7, 7, 7, 7, 7, 7, 7,12, 0, 0, 0
        db  0, 0, 6, 6,12, 7, 7, 7, 7, 7, 7, 7,12, 0, 0, 0
        db  0, 6, 6, 0,12, 7, 7,12,12,12, 7,12, 0, 0, 0, 0
        db  0, 6, 6, 0,12, 7, 7,12,12,12, 7,12, 0, 0, 0, 0
        db  0, 0, 6, 6,12,12,10,10,10,10,12,12, 0, 0, 0, 0
        db  0, 0, 6, 6,12,12,10,10,10,10,12,12, 0, 0, 0, 0
        db  0, 0, 0, 0, 0,12,10,10,10,10,10,10,12, 0, 0, 0
        db  0, 0, 0, 0, 0,12,10,10,10,10,10,10,12, 0, 0, 0
        db  0, 0, 0, 0, 7,12,10,10,10,10,10,10,12, 7, 0, 0
        db  0, 0, 0, 0, 7,12,10,10,10,10,10,10,12, 7, 0, 0
        db  0, 0, 0, 0, 7,12,10,10,10,10,10,10,12, 7, 0, 0
        db  0, 0, 0, 0, 7,12,10,10,10,10,10,10,12, 7, 0, 0
        db  0, 0, 0, 0, 0,12,14,14,14,14,14,14,12, 0, 0, 0
        db  0, 0, 0, 0, 0,12,14,14,14,14,14,14,12, 0, 0, 0
        db  0, 0, 0, 0, 0,12,14,14,12,12,14,14,12, 0, 0, 0
        db  0, 0, 0, 0, 0,12,14,14,12,12,14,14,12, 0, 0, 0
        db  0, 0, 0, 0,12, 3, 3,12, 0, 0,12, 3, 3,12, 0, 0
        db  0, 0, 0, 0,12, 3, 3,12, 0, 0,12, 3, 3,12, 0, 0
spr_super_run:                       ; super hero running (16x32)
        db  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
        db  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
        db  0, 0, 0, 0, 0,12,12,12,12,12, 0, 0, 0, 0, 0, 0
        db  0, 0, 0, 0, 0,12,12,12,12,12, 0, 0, 0, 0, 0, 0
        db  0, 0, 0, 0,12,15,15,15,15,15,12, 0, 0, 0, 0, 0
        db  0, 0, 0, 0,12,15,15,15,15,15,12, 0, 0, 0, 0, 0
        db  0, 0, 0,12,15,15,15,15,15,15,15,12,12, 0, 0, 0
        db  0, 0, 0,12,15,15,15,15,15,15,15,12,12, 0, 0, 0
        db  0, 0, 0,12,15,15,15,15,15,12,12,12,12,12, 0, 0
        db  0, 0, 0,12,15,15,15,15,15,12,12,12,12,12, 0, 0
        db  0, 0, 0,12,12, 7, 7, 7, 7, 7, 7,12, 0, 0, 0, 0
        db  0, 0, 0,12,12, 7, 7, 7, 7, 7, 7,12, 0, 0, 0, 0
        db  0, 0, 6, 6,12, 7, 7, 7, 9,12, 7, 7,12, 0, 0, 0
        db  0, 0, 6, 6,12, 7, 7, 7, 9,12, 7, 7,12, 0, 0, 0
        db  0, 0, 6, 6,12, 7, 7, 7, 7, 7, 7, 7,12, 0, 0, 0
        db  0, 0, 6, 6,12, 7, 7, 7, 7, 7, 7, 7,12, 0, 0, 0
        db  0, 6, 6, 0,12, 7, 7,12,12,12, 7,12, 0, 0, 0, 0
        db  0, 6, 6, 0,12, 7, 7,12,12,12, 7,12, 0, 0, 0, 0
        db  0, 0, 6, 6,12,12,10,10,10,10,12,12, 0, 0, 0, 0
        db  0, 0, 6, 6,12,12,10,10,10,10,12,12, 0, 0, 0, 0
        db  0, 0, 0, 0, 0,12,10,10,10,10,10,10,12, 0, 0, 0
        db  0, 0, 0, 0, 0,12,10,10,10,10,10,10,12, 0, 0, 0
        db  0, 0, 0, 7, 7,12,10,10,10,10,10,10,12, 0, 0, 0
        db  0, 0, 0, 7, 7,12,10,10,10,10,10,10,12, 0, 0, 0
        db  0, 0, 0, 0, 0,12,10,10,10,10,10,10,12, 7, 0, 0
        db  0, 0, 0, 0, 0,12,10,10,10,10,10,10,12, 7, 0, 0
        db  0, 0, 0, 0, 0,12,14,14,14,14,14,14,12, 0, 0, 0
        db  0, 0, 0, 0, 0,12,14,14,14,14,14,14,12, 0, 0, 0
        db  0, 0, 0, 0,12,14,14,12, 0,12,14,14,12, 0, 0, 0
        db  0, 0, 0, 0,12,14,14,12, 0,12,14,14,12, 0, 0, 0
        db  0, 0, 0,12, 3, 3,12, 0, 0, 0,12, 3, 3,12, 0, 0
        db  0, 0, 0,12, 3, 3,12, 0, 0, 0,12, 3, 3,12, 0, 0
spr_super_jump:                       ; super hero jumping (16x32)
        db  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
        db  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
        db  0, 0, 0, 0, 0,12,12,12,12,12, 0, 0, 0, 0, 0, 0
        db  0, 0, 0, 0, 0,12,12,12,12,12, 0, 0, 0, 0, 0, 0
        db  0, 0, 0, 0,12,15,15,15,15,15,12, 0, 0, 0, 0, 0
        db  0, 0, 0, 0,12,15,15,15,15,15,12, 0, 0, 0, 0, 0
        db  0, 0, 0,12,15,15,15,15,15,15,15,12,12, 0, 0, 0
        db  0, 0, 0,12,15,15,15,15,15,15,15,12,12, 0, 0, 0
        db  0, 0, 0,12,15,15,15,15,15,12,12,12,12,12, 0, 0
        db  0, 0, 0,12,15,15,15,15,15,12,12,12,12,12, 0, 0
        db  0, 0, 0,12,12, 7, 7, 7, 7, 7, 7,12, 0, 0, 7, 7
        db  0, 0, 0,12,12, 7, 7, 7, 7, 7, 7,12, 0, 0, 7, 7
        db  0, 0, 6, 6,12, 7, 7, 7, 9,12, 7, 7,12, 0, 7,12
        db  0, 0, 6, 6,12, 7, 7, 7, 9,12, 7, 7,12, 0, 7,12
        db  0, 0, 6, 6,12, 7, 7, 7, 7, 7, 7, 7,12,10,12, 0
        db  0, 0, 6, 6,12, 7, 7, 7, 7, 7, 7, 7,12,10,12, 0
        db  0, 6, 6, 0,12, 7, 7,12,12,12, 7,12,10,12, 0, 0
        db  0, 6, 6, 0,12, 7, 7,12,12,12, 7,12,10,12, 0, 0
        db  0, 0, 6, 6,12,12,10,10,10,10,12,12,12, 0, 0, 0
        db  0, 0, 6, 6,12,12,10,10,10,10,12,12,12, 0, 0, 0
        db  0, 0, 0, 0, 0,12,10,10,10,10,10,10,12, 0, 0, 0
        db  0, 0, 0, 0, 0,12,10,10,10,10,10,10,12, 0, 0, 0
        db  0, 0, 0, 0, 7,12,10,10,10,10,10,10,12, 0, 0, 0
        db  0, 0, 0, 0, 7,12,10,10,10,10,10,10,12, 0, 0, 0
        db  0, 0, 0, 0, 7,12,10,10,10,10,10,10,12, 0, 0, 0
        db  0, 0, 0, 0, 7,12,10,10,10,10,10,10,12, 0, 0, 0
        db  0, 0, 0,12,14,14,14,14,14,14,14,14,12, 0, 0, 0
        db  0, 0, 0,12,14,14,14,14,14,14,14,14,12, 0, 0, 0
        db  0, 0,12,14,14,14,12, 0, 0,12,14,14,14,12, 0, 0
        db  0, 0,12,14,14,14,12, 0, 0,12,14,14,14,12, 0, 0
        db  0, 0,12, 3, 3,12, 0, 0, 0, 0,12, 3, 3,12, 0, 0
        db  0, 0,12, 3, 3,12, 0, 0, 0, 0,12, 3, 3,12, 0, 0


; ---- Enemies (Module 11) ----
; one record = 16 bytes: type, state, x, xfrac, dir, y(feet), yfrac, ground, vy, timer, grace, spare
%macro ENEMY 3                  ; type, start x, start direction (0 right, 1 left)
        db      %1, ES_WAIT
        dw      %2
        db      0, %3
        dw      160
        db      0, 0
        dw      0
        dw      0
        db      0, 0
%endmacro
enemy_init:                     ; walkers and snails spread over the whole level
        ENEMY   ET_WALKER, 176, 1       ; column 11
        ENEMY   ET_WALKER, 336, 1       ; column 21
        ENEMY   ET_SNAIL, 500, 1       ; column 31
        ENEMY   ET_WALKER, 560, 1       ; column 35
        ENEMY   ET_WALKER, 600, 1       ; column 37
        ENEMY   ET_SNAIL, 660, 0       ; column 41
        ENEMY   ET_WALKER, 800, 1       ; column 50
        ENEMY   ET_SNAIL, 880, 1       ; column 55
        ENEMY   ET_WALKER, 1088, 1       ; column 68
        ENEMY   ET_WALKER, 1168, 1       ; column 73
        ENEMY   ET_SNAIL, 1248, 1       ; column 78
        ENEMY   ET_WALKER, 1536, 1       ; column 96
        ENEMY   ET_WALKER, 1648, 1       ; column 103
        ENEMY   ET_SNAIL, 1728, 1       ; column 108
        ENEMY   ET_WALKER, 1840, 1       ; column 115
        ENEMY   ET_WALKER, 2032, 1       ; column 127
        ENEMY   ET_SNAIL, 2160, 1       ; column 135
        ENEMY   ET_WALKER, 2416, 1       ; column 151
        ENEMY   ET_WALKER, 2512, 1       ; column 157
        ENEMY   ET_SNAIL, 2624, 1       ; column 164
        times MAX_ENEMIES * ENEMY_SIZE - ($ - enemy_init) db 0     ; free slots (for mushrooms)
enemy_table     times MAX_ENEMIES * ENEMY_SIZE db 0

fx_table        times MAX_FX * FX_SIZE db 0     ; coin effects
c_was_down      db 0
t_was_down      db 0
key_prev        times 128 db 0  ; key_state of the previous frame
key_edge        times 128 db 0  ; 1 = key went down in this frame
menu_sel        db 0            ; title menu: 0 = START GAME, 1 = EXIT
pause_tick      dw 0            ; last tick seen while paused (to freeze the clock)
dying_timer     dw 0            ; frames since Mario died
life_timer      dw 0            ; frames left on the Life-lost screen
death_kind      db 0            ; 0 alive, 1 hit or time (hop), 2 pit (no hop)
win_phase       db 0            ; 0 = sliding down the pole, 1 = walking away
win_timer       dw 0            ; frames of the walk
flag_award      dw 0            ; points given for the height of the flag contact
time_bonus      dw 0            ; time left x 50
flag_points     dw 5000, 5000, 5000, 5000, 2000, 800, 400, 400, 100     ; by map row 0..8
state_table     dw StateTitle, StatePlaying, StatePaused, StateDying, StateLifeLost
                dw StateWin, StateLevelDone, StateGameOver, StateExit
clock_ref       dw 0            ; timer tick at which the current clock second began
stomp_points    dw 100, 200, 400, 500, 800, 1000, 2000, 4000, 5000, 8000
ten             dw 10

; ---- Digit font: 10 digits, 7 rows each, 5 pixels per row (bit 4 = leftmost) ----
font_digits:
        db 0Eh,11h,13h,15h,19h,11h,0Eh          ; 0
        db 04h,0Ch,04h,04h,04h,04h,0Eh          ; 1
        db 0Eh,11h,01h,02h,04h,08h,1Fh          ; 2
        db 1Eh,01h,01h,0Eh,01h,01h,1Eh          ; 3
        db 02h,06h,0Ah,12h,1Fh,02h,02h          ; 4
        db 1Fh,10h,1Eh,01h,01h,11h,0Eh          ; 5
        db 06h,08h,10h,1Eh,11h,11h,0Eh          ; 6
        db 1Fh,01h,02h,04h,08h,08h,08h          ; 7
        db 0Eh,11h,11h,0Eh,11h,11h,0Eh          ; 8
        db 0Eh,11h,11h,0Fh,01h,02h,0Ch          ; 9

; ---- Letters A-Z: 7 rows each, 5 pixels per row (bit 4 = leftmost) ----
font_letters:
        db 0Eh,11h,11h,1Fh,11h,11h,11h                ; A
        db 1Eh,11h,11h,1Eh,11h,11h,1Eh                ; B
        db 0Eh,11h,10h,10h,10h,11h,0Eh                ; C
        db 1Ch,12h,11h,11h,11h,12h,1Ch                ; D
        db 1Fh,10h,10h,1Eh,10h,10h,1Fh                ; E
        db 1Fh,10h,10h,1Eh,10h,10h,10h                ; F
        db 0Eh,11h,10h,17h,11h,11h,0Fh                ; G
        db 11h,11h,11h,1Fh,11h,11h,11h                ; H
        db 0Eh,04h,04h,04h,04h,04h,0Eh                ; I
        db 07h,02h,02h,02h,02h,12h,0Ch                ; J
        db 11h,12h,14h,18h,14h,12h,11h                ; K
        db 10h,10h,10h,10h,10h,10h,1Fh                ; L
        db 11h,1Bh,15h,15h,11h,11h,11h                ; M
        db 11h,11h,19h,15h,13h,11h,11h                ; N
        db 0Eh,11h,11h,11h,11h,11h,0Eh                ; O
        db 1Eh,11h,11h,1Eh,10h,10h,10h                ; P
        db 0Eh,11h,11h,11h,15h,12h,0Dh                ; Q
        db 1Eh,11h,11h,1Eh,14h,12h,11h                ; R
        db 0Fh,10h,10h,0Eh,01h,01h,1Eh                ; S
        db 1Fh,04h,04h,04h,04h,04h,04h                ; T
        db 11h,11h,11h,11h,11h,11h,0Eh                ; U
        db 11h,11h,11h,11h,11h,0Ah,04h                ; V
        db 11h,11h,11h,15h,15h,15h,0Ah                ; W
        db 11h,11h,0Ah,04h,0Ah,11h,11h                ; X
        db 11h,11h,11h,0Ah,04h,04h,04h                ; Y
        db 1Fh,01h,02h,04h,08h,10h,1Fh                ; Z

; ---- Signs: symbol_chars lists them in the same order as the shapes below ----
symbol_chars    db '!-.:?x,+/', 27h, '>#|='
font_symbols:
        db 04h,04h,04h,04h,04h,00h,04h                ; !
        db 00h,00h,00h,1Fh,00h,00h,00h                ; -
        db 00h,00h,00h,00h,00h,0Ch,0Ch                ; .
        db 00h,0Ch,0Ch,00h,0Ch,0Ch,00h                ; :
        db 0Eh,11h,01h,02h,04h,00h,04h                ; ?
        db 00h,00h,11h,0Ah,04h,0Ah,11h                ; x
        db 00h,00h,00h,00h,0Ch,04h,08h                ; ,
        db 00h,04h,04h,1Fh,04h,04h,00h                ; +
        db 01h,01h,02h,04h,08h,10h,10h                ; /
        db 04h,04h,08h,00h,00h,00h,00h                ; '
        db 10h,08h,04h,02h,04h,08h,10h                ; >
        db 0Ah,0Ah,1Fh,0Ah,1Fh,0Ah,0Ah                ; #
        db 04h,04h,04h,04h,04h,04h,04h                ; |
        db 00h,00h,1Fh,00h,1Fh,00h,00h                ; =

; ---- Heart icons, 8 x 7 pixels, bit 7 = leftmost ----
heart_solid:    db 66h,0FFh,0FFh,0FFh,7Eh,3Ch,18h
heart_outline:  db 66h,99h,81h,81h,42h,24h,18h

; ---- HUD texts (zero-terminated) ----
txt_score       db 'SCORE', 0
txt_coins       db 'COINS', 0
txt_world       db 'WORLD', 0
txt_time        db 'TIME', 0
txt_lives       db 'LIVES', 0
txt_health      db 'HEALTH', 0
txt_level       db '1-1', 0

; ---- Screen texts ----
txt_title       db 'SUPER MARIO', 0
txt_engine      db 'E N G I N E', 0
txt_start       db 'START GAME', 0
txt_exit        db 'EXIT', 0
txt_team        db 'EL2003 COAL SEMESTER PROJECT', 0    ; <- you can put your group number and names here (capital letters)
txt_paused      db 'PAUSED', 0
txt_resume      db 'PRESS P TO RESUME', 0
txt_esc_title   db 'ESC FOR THE TITLE', 0
txt_level_name  db 'WORLD 1-1', 0
txt_get_ready   db 'GET READY!', 0
ll_lives        db 'x 00', 0                            ; the digits are filled in
txt_gameover    db 'G A M E   O V E R', 0
go_score        db 'FINAL SCORE: 000000', 0             ; digits at offset 13
go_line2        db 'COINS: 00    TIME: 000', 0          ; digits at offsets 7 and 19
txt_press_enter db 'PRESS ENTER FOR THE TITLE', 0
txt_level_done  db 'LEVEL COMPLETE', 0
lc_score        db 'SCORE: 000000', 0                   ; digits at offset 7
lc_coins        db 'COINS: 00', 0                       ; digits at offset 7
lc_flag         db 'FLAG BONUS: 00000', 0               ; digits at offset 12
lc_time         db 'TIME LEFT: 000 X 50 = 00000', 0     ; digits at offsets 11 and 22

; ---- Frame buffer (Module 5) ----
frame_seg       dw 0            ; segment number of the frame buffer, from DOS
msg_no_memory   db 'Not enough memory for the frame buffer.', 13, 10, '$'

; ---- Stage 8 test state ----
hero_pose_table dw spr_hero_stand, spr_hero_run, spr_hero_jump
                dw spr_super_stand, spr_super_run, spr_super_jump

; ---- Hero (Module 9) ----
hero_x          dw 0            ; whole pixels: world x of the left edge
hero_xf         db 0            ;   its fraction (1/256 pixel)
hero_y          dw 0            ; whole pixels: world y of the FEET
hero_yf         db 0            ;   its fraction
hero_vx         dw 0            ; sideways speed, 8.8 fixed point, signed
hero_vy         dw 0            ; vertical speed, 8.8 fixed point, signed (down = +)
hero_form       db 0            ; 0 = Small, 1 = Super
hero_hp         db 1            ; health 1 or 2
hero_on_ground  db 0
hero_facing     db 0            ; 0 = right, 1 = left
hero_jump_latch db 0            ; 1 while Space is held (one jump per press)
hero_invuln     dw 0
bump_flag       db 0            ; 1 = head hit a tile this frame (used by the block code)
bump_x          dw 0            ;   world x of the middle of the head
bump_y          dw 0            ;   world y of the top of the head
stomp_chain     dw 0
hero_prev_y     dw 0            ; feet of the previous frame (for the stomp test)

; ---- Camera, score, clock, state ----
camera_x        dw 0
score_lo        dw 0
score_hi        dw 0
coins           db 0
lives           db START_LIVES
level_clock     dw LEVEL_TIME
game_state      db ST_TITLE