-- (From Smash TV's tools/cpu_trace.lua; inputs from INPUTS=.)
-- MAME's debugger trace of the TMS34010 with the whole register file logged
-- before every instruction, for sim/run_cpu.sh:
--
--     =ST A0..A14 B0..B14 SP
--     PC: disassembly
--
-- Needs -debug -debugger none.  The bus trace is taken in a SEPARATE run, by
-- tools/bus_trace.lua with no debugger: the debugger's disassembler reads
-- every instruction through the address space before the CPU does, and a
-- memory tap cannot tell the two apart -- so with both in one run every
-- opcode fetch appears in the bus trace twice.  MAME is deterministic, and
-- the bench would notice at once if the two runs disagreed.
local mac = manager.machine
local dbg = mac.debugger
local dir = os.getenv("TRACE_DIR") or "."
local FRAMES = tonumber(os.getenv("TRACE_FRAMES") or "40")
local START  = tonumber(os.getenv("START_FRAME") or "0")

local regs = "st"
for i = 0, 14 do regs = regs .. ",a" .. i end
for i = 0, 14 do regs = regs .. ",b" .. i end
regs = regs .. ",sp"
local fmt = "=" .. string.rep("%08X ", 32)
-- CYCLES=1 appends the CPU's running cycle count, so the difference between
-- two lines is what MAME charged for the instruction between them (and any
-- interrupt entry).  sim/tb_cpu.cpp compares it with what the RTL charged.
if os.getenv("CYCLES") == "1" then
    regs = regs .. ",totalcycles"
    fmt = fmt .. "%X "
end
local function start_trace()
    dbg:command(string.format('trace %s/trace_reg.txt,maincpu,noloop,{tracelog "%s\\n",%s}',
                              dir, fmt, regs))
end
if START == 0 then start_trace() end
dbg.execution_state = "run"

local script = {}
if os.getenv("INPUTS") then
    for line in io.lines(os.getenv("INPUTS")) do
        local f, port, field, v = string.match(line, "^(%d+)%s+(%S+)%s+(.-)%s+(%d)%s*$")
        if f then f = tonumber(f); script[f] = script[f] or {}; table.insert(script[f], {port, field, tonumber(v)}) end
    end
end

local frames, tracing = 0, true
_G.KEEP = {}
_G.KEEP.n = emu.add_machine_frame_notifier(function()
    frames = frames + 1
    for _, a in ipairs(script[frames] or {}) do
        local fld = mac.ioport.ports[a[1]].fields[a[2]]
        if a[3] == 1 then fld:set_value(1) else fld:clear_value() end
    end
    if START > 0 and frames == START then start_trace() end
    if tracing and frames >= START + FRAMES then
        tracing = false
        dbg:command("trace off,maincpu")
    end
end)
_G.KEEP.s = emu.add_machine_stop_notifier(function()
    if tracing then dbg:command("trace off,maincpu") end
end)
