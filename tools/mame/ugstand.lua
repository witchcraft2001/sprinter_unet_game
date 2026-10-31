-- ugstand.lua -- MAME "sprinter" driver of the M stand (tools/mame/run_esp.py).
--
-- Waits for DSS to reach the File Manager, types the UGTEST command on the
-- PS/2 keyboard (ioport fields, as sources/games/battleship does), then
-- polls the report block of UGTEST.EXE (address from its symbol file) once
-- per frame.  When the program marks the report done, the text goes to
-- UG_REPORT_FILE and MAME exits; on a timeout the partial report is written
-- with "RESULT: FAIL (timeout)".
--
-- Environment: UG_SYM, UG_REPORT_FILE, UG_CMD (default b:\ugtest.exe),
-- UG_TIMEOUT (emulated seconds after the command, default 120), UG_BOOT
-- (emulated seconds to wait for DSS, default 10).

if _G.__ugstand_loaded then return end   -- MAME runs -autoboot_script twice
_G.__ugstand_loaded = true

local machine = manager.machine
local cpu = machine.devices[":maincpu"]
local prog = cpu.spaces["program"]
local SYM = assert(os.getenv("UG_SYM"), "UG_SYM not set")
local OUT = os.getenv("UG_REPORT_FILE") or "report.txt"
local CMD = os.getenv("UG_CMD") or "b:\\ugtest.exe"
local TIMEOUT = tonumber(os.getenv("UG_TIMEOUT") or "120")
local BOOT = tonumber(os.getenv("UG_BOOT") or "10")

local sym = {}
for line in io.lines(SYM) do
  local name, hex = line:match("^([%w_%.]+):%s*EQU%s+0x(%x+)")
  if name then sym[name] = tonumber(hex, 16) end
end
local REPORT = assert(sym.UG_REPORT, "UG_REPORT missing in " .. SYM)
local MAGIC = "UGTREP1"

local function now() return machine.time:as_double() end
local co
local function frames(n) for _ = 1, n do coroutine.yield() end end
-- the video frame period (the IM1 tick UGTEST calibrates against)
local frame_t, frame_n = nil, 0

-- keyboard
local fields = {}
for tag, port in pairs(machine.ioport.ports) do
  if tag:find("^:kbd:") then for fname, f in pairs(port.fields) do fields[fname] = f end end
end
local shifted = { [":"] = ";", ["_"] = "-", ["+"] = "=" }
local function keyname(ch)
  if ch:match("%l") then return ch:upper(), false end
  if ch:match("%u") then return ch, true end
  if ch == " " then return "Space", false end
  if ch == "\n" then return "Enter", false end
  if shifted[ch] then return shifted[ch], true end
  return ch, false
end
local HOLD = 3
local function press(ch)
  local name, sh = keyname(ch)
  local f = assert(fields[name], "no key field for '" .. ch .. "'")
  if sh then fields["Left Shift"]:set_value(1); frames(HOLD) end
  f:set_value(1); frames(HOLD)
  f:set_value(0)
  if sh then frames(HOLD); fields["Left Shift"]:set_value(0) end
  frames(HOLD)
end
local function type_line(s)
  for i = 1, #s do press(s:sub(i, i)) end
  press("\n")
end

-- report block
local function magic_ok()
  for i = 1, #MAGIC do
    if prog:read_u8(REPORT + i - 1) ~= MAGIC:byte(i) then return false end
  end
  return true
end
local function report_text()
  local t = {}
  for a = REPORT + 16, REPORT + 0x67F do
    local b = prog:read_u8(a)
    if b == 0 then break end
    t[#t + 1] = string.char(b)
  end
  return table.concat(t)
end

local function scenario()
  while now() < BOOT do frames(1) end
  type_line(CMD)
  local t0 = now()
  local seen = false
  local clk = {}                          -- (emulated s, UGTEST now_ms) samples
  while now() - t0 < TIMEOUT do
    frames(1)
    if magic_ok() then
      if sym.now_ms and (#clk == 0 or now() - clk[#clk][1] >= 0.5) then
        clk[#clk + 1] = { now(), prog:read_u32(sym.now_ms), sym.st_n and prog:read_u16(sym.st_n) or 0, sym.ticks and prog:read_u16(sym.ticks) or 0 }
      end
      seen = true
      if prog:read_u8(REPORT + 10) == 0xA5 then
        local dt = now() - t0
        frames(25)                        -- let the DSS print finish
        local rate = ""
        if #clk >= 3 then
          local a, b = clk[2], clk[#clk]
          rate = string.format("CLOCK_RATE %.3f now_ms per emulated ms, TICK_MS %.3f, FRAME_MS %.3f, STEP_CALLS_PER_S %.0f (over %.1f s)\r\n",
            (b[2] - a[2]) / ((b[1] - a[1]) * 1000), (b[1] - a[1]) * 1000 / math.max(1, b[4] - a[4]),
            FRAME_MS or 0, (b[3] - a[3]) / (b[1] - a[1]), b[1] - a[1])
        end
        return report_text() .. string.format("EMULATED_RUN_S %.3f\r\n", dt) .. rate, true
      end
    end
  end
  return (seen and report_text() or "(no report block)") .. "\r\nRESULT: FAIL (timeout)\r\n", false
end

co = coroutine.create(function()
  local ok, text = pcall(scenario)
  local f = io.open(OUT, "w")
  if ok then f:write(text) else f:write("SCRIPT ERROR: " .. tostring(text) .. "\r\nRESULT: FAIL (script)\r\n") end
  f:write(string.format("\r\nemulated time %.1f s\r\n", now()))
  f:close()
  pcall(function() machine.screens[":screen"]:snapshot("final.png") end)
  machine:exit()
end)

emu.register_frame_done(function()
  local t = now()
  if not frame_t then frame_t = t elseif frame_n < 100 then frame_n = frame_n + 1 end
  if frame_n == 100 and not FRAME_MS then FRAME_MS = (t - frame_t) * 1000 / 100 end
  if co and coroutine.status(co) == "suspended" then
    local ok, err = coroutine.resume(co)
    if not ok then print("ugstand: " .. tostring(err)); machine:exit() end
  end
end)
