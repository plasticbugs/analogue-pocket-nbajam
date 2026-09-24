-- A sound-board test that exercises every chip: while the game waits on its
-- CMOS-invalid screen (fresh NVRAM, no button pressed -- it sends the sound
-- board nothing there), write sound commands FIRST..LAST to the latch one
-- every STEP seconds, starting at START s, logging each with machine time
-- in snd_log.lua's format.  Run with -wavwrite; replay the log with
-- sim/run_sound.sh.
--
--   rm -rf .mame/nvram/nbajam
--   OUT=artifacts/audio/sweep_cmds.txt tools/mame.sh -seconds_to_run 66 \
--       -wavwrite artifacts/audio/mame_sweep.wav -autoboot_script tools/snd_sweep.lua
local mac = manager.machine
local sp  = mac.devices[":maincpu"].spaces["program"]
local out = io.open(os.getenv("OUT"), "w")
local FIRST = tonumber(os.getenv("FIRST") or "0")
local LAST  = tonumber(os.getenv("LAST") or "95")
local STEP  = tonumber(os.getenv("STEP") or "0.6")
local START = tonumber(os.getenv("START") or "5")
local keep = {}
local nextcmd, due = FIRST, START
keep.t = sp:install_write_tap(0x01d01020, 0x01d0103f, "snd", function(off, data, mask)
  out:write(string.format("%.9f %x %04x %04x\n", mac.time:as_double(), off, data, mask))
end)
keep.f = emu.register_frame_done(function()
  keep.t:reinstall()
  local t = mac.time:as_double()
  if nextcmd <= LAST and t >= due then
    sp:write_u16(0x01d01030, 0xff00 | nextcmd)
    nextcmd = nextcmd + 1
    due = due + STEP
  end
  out:flush()
end)
