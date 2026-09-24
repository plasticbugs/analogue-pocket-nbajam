-- Replay an input script (tools/inputs/*.txt: "frame port field value") and
-- nothing else -- for MAME recordings (-wavwrite, -snapshot) that must line
-- up with the benches, which replay the same scripts.
--
--   rm -rf .mame/nvram/nbajam
--   INPUTS=tools/inputs/play1.txt tools/mame.sh -seconds_to_run 27 \
--       -wavwrite artifacts/audio/mame.wav -autoboot_script tools/play_inputs.lua
local mac = manager.machine
local script = {}
for line in io.lines(os.getenv("INPUTS")) do
  local f, port, field, v = string.match(line, "^(%d+)%s+(%S+)%s+(.-)%s+(%d)%s*$")
  if f then f = tonumber(f); script[f] = script[f] or {}; table.insert(script[f], {port, field, tonumber(v)}) end
end
local frames = 0
_G.KEEP = {}
_G.KEEP.n = emu.register_frame_done(function()
  frames = frames + 1
  for _, a in ipairs(script[frames] or {}) do
    local fld = mac.ioport.ports[a[1]].fields[a[2]]
    if a[3] == 1 then fld:set_value(1) else fld:clear_value() end
  end
end)
