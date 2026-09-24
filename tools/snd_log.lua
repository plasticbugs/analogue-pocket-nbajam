-- Log every write the main CPU makes to the sound board (01d0_1020-01d0_103f),
-- with MAME's machine time, while -wavwrite records the audio of the same run:
-- sim/run_sound.sh replays the commands into rtl/tunit_sound.sv at the same
-- times and compares its output with the recording (METHODOLOGY 5.10).
--
--   rm -rf .mame/nvram/nbajam
--   INPUTS=tools/inputs/play1.txt OUT=artifacts/audio/mame_play1_cmds.txt \
--     tools/mame.sh -seconds_to_run 66 -wavwrite artifacts/audio/mame_play1.wav \
--     -autoboot_script tools/snd_log.lua
--
-- One line per write: "time(s) offset data mask".  Time zero is when the
-- recording starts, which is machine time zero.
local mac = manager.machine
local sp  = mac.devices[":maincpu"].spaces["program"]
local out = io.open(os.getenv("OUT"), "w")
local script = {}
if os.getenv("INPUTS") then
  for line in io.lines(os.getenv("INPUTS")) do
    local f, port, field, v = string.match(line, "^(%d+)%s+(%S+)%s+(.-)%s+(%d)%s*$")
    if f then f = tonumber(f); script[f] = script[f] or {}; table.insert(script[f], {port, field, tonumber(v)}) end
  end
end
local keep, frames = {}, 0
keep.t = sp:install_write_tap(0x01d01020, 0x01d0103f, "snd", function(off, data, mask)
  out:write(string.format("%.9f %x %04x %04x\n", mac.time:as_double(), off, data, mask))
end)
keep.f = emu.register_frame_done(function()
  keep.t:reinstall()
  out:flush()
  frames = frames + 1
  for _, a in ipairs(script[frames] or {}) do
    local fld = mac.ioport.ports[a[1]].fields[a[2]]
    if a[3] == 1 then fld:set_value(1) else fld:clear_value() end
  end
end)
