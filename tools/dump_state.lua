-- Dump nbajam's whole video state at chosen frames, with MAME's own output
-- for the same frame, and (optionally) every write that changes the video
-- state in between, so the reference renderer and the blitter model can be
-- checked against MAME.
--
--   rm -rf .mame/nvram/nbajam
--   FRAMES=400,2600 OUT=artifacts/states tools/mame.sh \
--       -seconds_to_run 60 -autoboot_script tools/dump_state.lua
--
-- For every N in FRAMES it dumps frames N-1 and N and logs the writes between
-- them to events_N.txt: state N-1 plus the events is what the blitter model
-- and the RTL replay, state N is what they must reproduce, and MAME's picture
-- in state N is what the scan-out of state N-1 must show (MAME's frame N is
-- scanned from the page DPYSTRT selected at the end of frame N-1).
--
-- LOAD=file writes one line a frame: the blits started, their pixel count
-- (width x height, MAME's timing count unscaled) and the sound commands --
-- the timeline the machine bench's log is lined up against.
--
-- INPUTS=file replays a recorded input script (tools/inputs/*.txt): lines
-- "frame port field value", value 1 = pressed, 0 = released.
--
-- state_NNNNN.bin, little-endian:
--   "NJST", u32 version=1, u32 frame
--   u16 ioregs[32]          TMS34010 I/O registers C0000000..
--   u16 control             the T-unit control latch (as last written)
--   u16 dmaregs[18]         the blitter registers as last written (0..15, then
--                           the LEFTCLIP/RIGHTCLIP pseudo-registers 16, 17)
--   u16 palette[32768]
--   u16 vram[524288]        every pixel, colour byte high, data byte low
--   u32 pixels[H][W]        screen:pixels(), MAME's output for the frame
--
-- events_N.txt: every write, in order, from the end of frame N-1 to the end
-- of frame N, one per line:
--   R reg data mask         blitter register write (reg = raw offset 0..15)
--   C data mask             control latch write (either decode)
--   V wordoff data mask     CPU write to VRAM (word offset = bit address >> 4)
--   I reg data line         write to a TMS34010 I/O register the video
--                           depends on (DPYCTL, DPYSTRT, DPYINT, CONTROL,
--                           PSIZE, DPYTAP, DPYADR), and the beam's line then
--                           (fractional, from machine time; MAME 0.288's Lua
--                           has no screen:vpos(), and calling it killed this tap)
--   T addr                  shift register loaded from VRAM bit address addr
--   S daddr pitch dydx      a FILL through the shift register: each of the
--                           dydx>>16 rows at daddr + i*pitch gets the shift
--                           register's 1024 pixels
--
-- The last two are how the game clears a page: its display-interrupt handler
-- (ff8262f0) sets DPYCTL.SRT, does PIXT *A2,A2 with A2 = 1FE000 (rows 510-511,
-- always zero) and then FILL L at PSIZE 16 over 127 double rows.  With SRT set
-- MAME routes those pixel accesses to the shift-register callbacks, so no
-- memory tap sees them; they are synthesised here from the I/O writes and the
-- CPU's registers, which the handler's code fixes (docs/hardware.md 7.4).
--   F frame                 end of a frame
--
-- The VRAM is read through the CPU's own handler with the latch's bank bit
-- set and then clear, which is the only way Lua can see both halves of a
-- pixel; the latch is put back as it was.  Nothing else is touched.
local mac = manager.machine
local sp  = mac.devices[":maincpu"].spaces["program"]
local out = os.getenv("OUT") or "."
local BUTTON = 150
local COIN  = tonumber(os.getenv("COIN") or "1500")
local START = tonumber(os.getenv("START") or "1600")

local want, logat = {}, {}
for n in string.gmatch(os.getenv("FRAMES") or "400", "%d+") do
  n = tonumber(n); want[n] = true; want[n - 1] = true; logat[n - 1] = n
end
local script = {}
if os.getenv("INPUTS") then
  for line in io.lines(os.getenv("INPUTS")) do
    local f, port, field, v = string.match(line, "^(%d+)%s+(%S+)%s+(.-)%s+(%d)%s*$")
    if f then
      f = tonumber(f)
      script[f] = script[f] or {}
      table.insert(script[f], {port, field, tonumber(v)})
    end
  end
end

local keep = {}
local frame = 0
local control = 0xfff8          -- MAME resets it to 0; the game writes fff8 at once
local dmaregs = {}
for i = 0, 17 do dmaregs[i] = 0 end
local ev = nil
local load = os.getenv("LOAD") and io.open(os.getenv("LOAD"), "w") or nil
local ld_blits, ld_pix, ld_snd = 0, 0, {}
local busy = false              -- our own latch writes must not be logged

local function evw(s) if ev then ev:write(s) end end

keep[#keep+1] = sp:install_write_tap(0x01a80000, 0x01a800ff, "dma", function(off, data, mask)
  local r = (off - 0x01a80000) >> 4
  local regbank = (dmaregs[15] >> 5) & 1
  local reg = r
  if regbank == 0 and r == 12 then reg = 16 elseif regbank == 0 and r == 13 then reg = 17 end
  dmaregs[reg] = (dmaregs[reg] & ~mask) | (data & mask)
  evw(string.format("R %d %04x %04x\n", r, data, mask))
  if r == 1 and (data & 0x8000) ~= 0 then
    ld_blits = ld_blits + 1
    ld_pix = ld_pix + (dmaregs[6] & 0x3ff) * (dmaregs[7] & 0x3ff)
  end
end)
local function ctl(off, data, mask)
  if busy then return end
  control = (control & ~mask) | (data & mask)
  evw(string.format("C %04x %04x\n", data, mask))
end
keep[#keep+1] = sp:install_write_tap(0x01b00000, 0x01b0001f, "ctl", ctl)
keep[#keep+1] = sp:install_write_tap(0x01f00000, 0x01f0001f, "ctl2", ctl)
keep[#keep+1] = sp:install_write_tap(0x01d01020, 0x01d0103f, "snd", function(off, data, mask)
  ld_snd[#ld_snd + 1] = string.format("%04x", data)
end)
keep[#keep+1] = sp:install_write_tap(0x00000000, 0x003fffff, "vram", function(off, data, mask)
  evw(string.format("V %x %04x %04x\n", off >> 4, data, mask))
end)

local scr = mac.screens[":screen"]
local cpu = mac.devices[":maincpu"]
local IOLOG = {[8]=true, [9]=true, [10]=true, [11]=true, [21]=true, [27]=true, [30]=true}
local srt, fill_daddr = false, nil
-- The beam's line, from machine time: frame_done fires at the start of vblank,
-- line 274 (VSBLNK), at exact multiples of the frame period (0.01827925 s,
-- measured) and a frame is 289 lines.  MAME 0.288's Lua has no screen:vpos().
local PERIOD = 506 * 289 / 8000000
local function beam_line()
  local t = mac.time:as_double()
  return (274 + (t % PERIOD) / PERIOD * 289) % 289
end
keep[#keep+1] = sp:install_write_tap(0xc0000000, 0xc00001ff, "io", function(off, data, mask)
  local r = (off - 0xc0000000) >> 4
  if IOLOG[r] then evw(string.format("I %d %04x %.2f\n", r, data, beam_line())) end
  if r == 8 then
    local on = (data & 0x0800) ~= 0
    -- ff826390: PIXT *A2,A2 with A2 = 1FE000 right after SRT goes on
    if on and not srt then evw("T 1fe000\n") end
    srt = on
  elseif r == 21 and srt then
    if data == 0x10 then
      fill_daddr = cpu.state["B2"].value
    elseif fill_daddr then
      evw(string.format("S %x %x %x\n", fill_daddr, cpu.state["B3"].value, cpu.state["B7"].value))
      fill_daddr = nil
    end
  end
end)

local function u16s(t)
  local s = {}
  for i = 1, #t do s[i] = string.char(t[i] & 0xff, (t[i] >> 8) & 0xff) end
  return table.concat(s)
end
local function u32(v) return string.char(v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff, (v >> 24) & 0xff) end

local function dump(n)
  local f = io.open(string.format("%s/state_%05d.bin", out, n), "wb")
  f:write("NJST", u32(1), u32(n))
  local t = {}
  for i = 0, 31 do t[#t+1] = sp:read_u16(0xC0000000 + i * 16) end
  f:write(u16s(t))
  f:write(u16s({control}))
  t = {}
  for i = 0, 17 do t[#t+1] = dmaregs[i] end
  f:write(u16s(t))
  -- palette: 32K words at 01800000
  local chunk = {}
  for i = 0, 32767 do
    local v = sp:read_u16(0x01800000 + i * 16)
    chunk[#chunk+1] = string.char(v & 0xff, v >> 8)
    if #chunk == 4096 then f:write(table.concat(chunk)); chunk = {} end
  end
  f:write(table.concat(chunk)); chunk = {}
  -- VRAM: data bytes with bank 1, colour bytes with bank 0
  busy = true
  local data = {}
  sp:write_u16(0x01f00000, control | 0x0020)
  for o = 0, 262143 do data[o] = sp:read_u16(o * 16) end
  sp:write_u16(0x01f00000, control & ~0x0020)
  for o = 0, 262143 do
    local d, c = data[o], sp:read_u16(o * 16)
    local p0 = ((c & 0xff) << 8) | (d & 0xff)
    local p1 = (c & 0xff00) | (d >> 8)
    chunk[#chunk+1] = string.char(p0 & 0xff, p0 >> 8, p1 & 0xff, p1 >> 8)
    if #chunk == 4096 then f:write(table.concat(chunk)); chunk = {} end
  end
  f:write(table.concat(chunk)); chunk = {}
  sp:write_u16(0x01f00000, control)
  busy = false
  -- MAME's output
  local px = scr:pixels()
  f:write(px)
  f:close()
  print(string.format("dumped frame %d (%d bytes of pixels)", n, #px))
end

keep[#keep+1] = emu.register_frame_done(function()
  for _, h in ipairs(keep) do if h.reinstall then h:reinstall() end end
  frame = frame + 1
  if load then
    load:write(string.format("frame %d blits %d pix %d snd %s\n", frame, ld_blits, ld_pix, table.concat(ld_snd, ",")))
    load:flush()
    ld_blits, ld_pix, ld_snd = 0, 0, {}
  end
  if ev then
    ev:write(string.format("F %d\n", frame))
    ev:close(); ev = nil
  end
  if want[frame] then dump(frame) end
  if logat[frame] then
    ev = io.open(string.format("%s/events_%05d.txt", out, logat[frame]), "w")
    ev:write(string.format("F %d\n", frame))
  end
  for _, a in ipairs(script[frame] or {}) do
    local fld = mac.ioport.ports[a[1]].fields[a[2]]
    if a[3] == 1 then fld:set_value(1) else fld:clear_value() end
  end
  local in0 = mac.ioport.ports[":IN0"]
  local in1 = mac.ioport.ports[":IN1"]
  if frame == BUTTON then in0.fields["P1 Turbo"]:set_value(1) end
  if frame == BUTTON + 8 then in0.fields["P1 Turbo"]:clear_value() end
  for _, c in ipairs({COIN, COIN + 20}) do
    if frame == c then in1.fields["Coin 1"]:set_value(1) end
    if frame == c + 8 then in1.fields["Coin 1"]:clear_value() end
  end
  if frame == START then in1.fields["1 Player Start"]:set_value(1) end
  if frame == START + 8 then in1.fields["1 Player Start"]:clear_value() end
end)
