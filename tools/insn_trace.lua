-- Instruction traces from MAME's debugger, in windows, so the set of TMS34010
-- instructions NBA Jam executes is measured rather than guessed (the pattern
-- is Smash TV's tools/insn_trace.lua).
--
--   rm -rf .mame/nvram/nbajam
--   TRACE_DIR=artifacts/insn INPUTS=tools/inputs/play1.txt tools/mame.sh -debug \
--       -debugger none -autoboot_script tools/insn_trace.lua -seconds_to_run 100
--   python3 tools/insn_hist.py artifacts/insn
--
-- One file per window, tr_<frame>.txt, WINDOW frames long; the first starts
-- at reset, where the self-tests are.  Note: a -debug run is not the same
-- emulation as a plain one (it diverges within seconds), so these windows
-- are for coverage, not for comparing against the frozen states.
local mac = manager.machine
local dbg = mac.debugger
local dir = os.getenv("TRACE_DIR") or "."
local WINDOW = tonumber(os.getenv("WINDOW") or "12")
local STARTS = {}
for n in string.gmatch(os.getenv("STARTS") or "0,160,400,1000,1400,1700,1900,2300,2500,3000,3500,4000,5200", "%d+") do
  STARTS[tonumber(n)] = true
end
local script = {}
if os.getenv("INPUTS") then
  for line in io.lines(os.getenv("INPUTS")) do
    local f, port, field, v = string.match(line, "^(%d+)%s+(%S+)%s+(.-)%s+(%d)%s*$")
    if f then f = tonumber(f); script[f] = script[f] or {}; table.insert(script[f], {port, field, tonumber(v)}) end
  end
end
local frames, stop_at = 0, nil
local function start(n)
  dbg:command(string.format("trace %s/tr_%05d.txt,maincpu,noloop", dir, n))
  stop_at = n + WINDOW
end
if STARTS[0] then start(0) end
dbg.execution_state = "run"

_G.KEEP = {}
_G.KEEP.s = emu.add_machine_stop_notifier(function()
  if stop_at then dbg:command("trace off,maincpu") end
end)
_G.KEEP.n = emu.add_machine_frame_notifier(function()
  frames = frames + 1
  for _, a in ipairs(script[frames] or {}) do
    local fld = mac.ioport.ports[a[1]].fields[a[2]]
    if a[3] == 1 then fld:set_value(1) else fld:clear_value() end
  end
  if stop_at and frames >= stop_at then
    dbg:command("trace off,maincpu"); stop_at = nil
  end
  if STARTS[frames] and not stop_at then start(frames) end
end)
