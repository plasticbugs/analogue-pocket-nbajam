-- First look at the running board: per-frame DMA blitter load, sound
-- commands, protection and CMOS traffic, the TMS34010 display registers,
-- and a MAME snapshot every SNAP frames.
--
--   rm -rf .mame/nvram/nbajam
--   OUT=artifacts/probe tools/mame.sh -seconds_to_run 90 \
--       -snapshot_directory artifacts/probe -autoboot_script tools/probe_board.lua
--
-- Two MAME Lua traps, both paid for here:
--  * keep every tap and notifier handle, or the collector removes it and
--    the tap silently stops firing;
--  * a tap callback must return NOTHING.  A returned value -- even nil --
--    is taken as replacement data, and the tap dies on the first write;
--  * on this driver taps are dropped every so often while the game runs
--    (seen after the CMOS reset and again a few hundred frames into
--    attract), so every tap is reinstalled at the end of every frame.
local mac = manager.machine
local sp  = mac.devices[":maincpu"].spaces["program"]
local out = os.getenv("OUT") or "."
local SNAP  = tonumber(os.getenv("SNAP") or "250")
local BUTTON = 150                                  -- past "CMOS invalid"
local COIN  = tonumber(os.getenv("COIN") or "1500")
local START = tonumber(os.getenv("START") or "1600")
local LAST  = tonumber(os.getenv("LAST") or "4800")

local keep = {}
local frame = 0
local log = io.open(out .. "/probe.log", "w")
local dmaregs = {}
local fr = {dma=0, pix=0, snd=0, prot=0, cmos=0, ctrl=0}
local tot = {dma=0, pix=0}
local maxpix, maxdma = 0, 0
local cmds = {}

keep[#keep+1] = sp:install_write_tap(0x01a80000, 0x01a800ff, "dma", function(off, data, mask)
  local r = (off - 0x01a80000) >> 4
  dmaregs[r] = data
  if r == 1 and (data & 0x8000) ~= 0 then
    fr.dma = fr.dma + 1
    local w = (dmaregs[6] or 0) & 0x3ff
    local h = (dmaregs[7] or 0) & 0x3ff
    local sx, sy = dmaregs[10] or 0, dmaregs[11] or 0
    local n = w * h
    if sx ~= 0 and sx ~= 0x100 then n = n * 256 // sx end
    if sy ~= 0 and sy ~= 0x100 then n = n * 256 // sy end
    fr.pix = fr.pix + n
    local key = string.format("%04x", data & 0xffff)
    cmds[key] = (cmds[key] or 0) + 1
  end
end)
keep[#keep+1] = sp:install_write_tap(0x01d01020, 0x01d0103f, "snd", function(off, data, mask)
  fr.snd = fr.snd + 1
  log:write(string.format("SND f=%d off=%x data=%04x mask=%04x\n", frame, off, data, mask))
end)
keep[#keep+1] = sp:install_read_tap(0x01b14020, 0x01b2503f, "protr", function(off, data, mask)
  fr.prot = fr.prot + 1
end)
keep[#keep+1] = sp:install_write_tap(0x01b14020, 0x01b2503f, "protw", function(off, data, mask)
  fr.prot = fr.prot + 1
  log:write(string.format("PROTW f=%d off=%08x data=%04x\n", frame, off, data))
end)
keep[#keep+1] = sp:install_write_tap(0x01400000, 0x0141ffff, "cmos", function(off, data, mask)
  fr.cmos = fr.cmos + 1
end)
keep[#keep+1] = sp:install_write_tap(0x01b00000, 0x01b0001f, "ctl", function(off, data, mask)
  fr.ctrl = fr.ctrl + 1
  if frame < 400 then log:write(string.format("CTRL f=%d data=%04x mask=%04x\n", frame, data, mask)) end
end)
keep[#keep+1] = sp:install_write_tap(0x01f00000, 0x01f0001f, "ctl2", function(off, data, mask)
  log:write(string.format("CTRL2 f=%d data=%04x\n", frame, data))
end)

local function ioregs()
  local t = {}
  for i = 0, 31 do t[#t+1] = string.format("%04x", sp:read_u16(0xC0000000 + i*16)) end
  return table.concat(t, " ")
end

local function finish()
  log:write(string.format("END frames=%d totdma=%d totpix=%d maxpix/frame=%d maxdma/frame=%d\n",
    frame, tot.dma, tot.pix, maxpix, maxdma))
  local ks = {}
  for k, _ in pairs(cmds) do ks[#ks+1] = k end
  table.sort(ks)
  for _, k in ipairs(ks) do log:write(string.format("CMD %s %d\n", k, cmds[k])) end
  log:close()
  log = nil
end

keep[#keep+1] = emu.register_frame_done(function()
  if not log then return end
  for _, h in ipairs(keep) do if h.reinstall then h:reinstall() end end
  frame = frame + 1
  log:write(string.format("F %d dma=%d pix=%d snd=%d prot=%d cmos=%d ctrl=%d\n",
    frame, fr.dma, fr.pix, fr.snd, fr.prot, fr.cmos, fr.ctrl))
  tot.dma = tot.dma + fr.dma; tot.pix = tot.pix + fr.pix
  if fr.pix > maxpix then maxpix = fr.pix end
  if fr.dma > maxdma then maxdma = fr.dma end
  fr = {dma=0, pix=0, snd=0, prot=0, cmos=0, ctrl=0}
  if frame % SNAP == 0 then
    mac.video:snapshot()
    log:write("IO " .. frame .. " " .. ioregs() .. "\n")
  end
  local in0 = mac.ioport.ports[":IN0"]
  local in1 = mac.ioport.ports[":IN1"]
  if frame == BUTTON then in0.fields["P1 Turbo"]:set_value(1) end
  if frame == BUTTON + 8 then in0.fields["P1 Turbo"]:clear_value() end
  if frame == COIN then in1.fields["Coin 1"]:set_value(1) end
  if frame == COIN + 8 then in1.fields["Coin 1"]:clear_value() end
  if frame == START then in1.fields["1 Player Start"]:set_value(1) end
  if frame == START + 8 then in1.fields["1 Player Start"]:clear_value() end
  if frame == LAST then finish() end
end)
