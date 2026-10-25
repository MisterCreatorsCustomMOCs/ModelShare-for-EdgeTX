-- TNS|Model Share|TNE
-- Model Share: send models, files or whole folders from one EdgeTX radio to another
-- over a 3.5 mm trainer cable or a serial cable.
-- Author: MisterCreators Custom MOCs
--
-- Run it from SYS -> Tools -> "Model Share" on both radios.
--
-- Trainer cable (default): connect the trainer jacks with a 3.5 mm cable.
--   Sending radio:   model with Trainer mode "Slave/Jack", RF modules off.
--                    Model Share adds mixes CH1-CH8 = GV1-GV8 to it and drives the GVs.
--   Receiving radio: model with Trainer mode "Master/Jack", reads TR1-TR8.
--   One direction only: the sender repeats everything until you stop it.
-- Serial: both radios need a serial port set to "LUA" (SYS -> Hardware -> Serial ports),
--   wired TX -> RX, RX -> TX, GND -> GND, same baud rate on both sides.
--
-- Touch:  tap a list entry to open / send it, swipe or "Up" / "Dn" to scroll, "X" = back
-- Keys:   PREV / NEXT select (hold to repeat), PAGE scrolls, ENTER = open / send, EXIT / RTN = back

local PROTO     = "MS1" -- protocol id, must match on both radios
local CHUNK     = 64    -- payload bytes per data packet
local TIMEOUT   = 50    -- reply timeout in 10 ms ticks
local MAX_RETRY = 20    -- resends per packet before the transfer is aborted
local PING_EVERY = 50   -- "I am here" packet interval in 10 ms ticks
local ONLINE_FOR = 150  -- the other radio counts as online this long after its last packet
local TEST_ROUNDS = 20  -- echo packets sent by the connection test

-- trainer link
-- ticks each symbol stays on the channels, chosen in the menu ("Speed")
-- The hold must be longer than the receiver's longest gap between two reads plus about
-- one PPM frame (~22 ms). Example: a receiver reading every 50-60 ms needs about 80 ms.
local T_SPEEDS   = { { name = "Safe", hold = 20 }, { name = "Normal", hold = 12 },
                     { name = "Fast", hold = 8 }, { name = "Turbo", hold = 7 } }
local T_CHUNK    = 60     -- payload bytes per data packet
local T_CLK      = 800    -- clock level on CH1, also the reference for gain and offset
local T_RANGE    = 900    -- data levels are spread over -T_RANGE .. +T_RANGE
local T_MAX_FILE = 65536  -- larger files are too slow for the trainer link
local MIX_NAME   = "MShare"

-- SLIP framing bytes
local END, ESC, ESC_END, ESC_ESC = "\192", "\219", "\220", "\221"
local SLIP_ENC = { [END] = ESC .. ESC_END, [ESC] = ESC .. ESC_ESC }
local SLIP_DEC = { [ESC_END] = END, [ESC_ESC] = ESC }

local COL_BG   = lcd.RGB(20, 20, 30)
local COL_BAR  = lcd.RGB(35, 40, 60)
local COL_TEXT = lcd.RGB(255, 255, 255)
local COL_DIM  = lcd.RGB(150, 150, 160)
local COL_SEL  = lcd.RGB(50, 60, 90)
local COL_BTN  = lcd.RGB(50, 60, 90)
local COL_OK   = lcd.RGB(0, 150, 60)
local COL_ERR  = lcd.RGB(200, 50, 50)
local COL_WARN = lcd.RGB(230, 150, 0)

local BAR_H  = 44 -- title bar and bottom bar height
local ROW_H  = 32 -- list row, rows with a description line are ROW_DESC high
local ROW_DESC = 46
local LIST_Y = BAR_H + 4
local DRAG   = 12 -- finger movement in pixels that turns a touch into a scroll

-- key events, the radio decides which of them exist
local function keySet(...)
  local s = {}
  for i = 1, select("#", ...) do
    local e = select(i, ...)
    if e then s[e] = true end
  end
  return s
end
local KEY_NEXT = keySet(EVT_VIRTUAL_NEXT, EVT_VIRTUAL_NEXT_REPT)
local KEY_PREV = keySet(EVT_VIRTUAL_PREV, EVT_VIRTUAL_PREV_REPT)
local KEY_PGDN = keySet(EVT_VIRTUAL_NEXT_PAGE)
local KEY_PGUP = keySet(EVT_VIRTUAL_PREV_PAGE)

local state = "menu"
local overwrite = false
local listSel, listTop = 1, 1
local followSel = true -- false after a swipe: the list stays where the finger left it
local touch            -- current touch: start y, list position, scrolling, end time
local rowH = ROW_DESC
local regions, lastRegions = {}, {}

local models, nameIdx = {}, 1
local cwd, browseItems = "/", {}
local scan, tx, rx
local doneTitle, doneLines, doneOk = "", {}, true
local rxBuf = ""

local myRadio = "?"
local lastPing = -1000
local peerTime, peerProto, peerRadio = -1000, nil, nil
local peerSending = -1000 -- last time the other radio tried to start a transfer
local portText, portCol = "", nil
local test
local link = "trainer" -- "trainer" or "serial"
local tSpeed = 2       -- index into T_SPEEDS
local trainerRole      -- trainer mode of the active model: "slave", "master", "off" or nil = unknown
local menuHint, menuHintTime = nil, -1000
local ts, tr           -- trainer sender / receiver state
local tStartSend, tStartReceive -- defined in the trainer section

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

-- Fletcher-16, can be continued over several strings
local function fletcher(s, a, b)
  a, b = a or 0, b or 0
  for i = 1, #s do
    a = (a + string.byte(s, i)) % 255
    b = (b + a) % 255
  end
  return a, b
end

local function join(d, n)
  if d == "/" then return "/" .. n end
  return d .. "/" .. n
end

local function parent(p)
  return string.match(p, "^(.*)/[^/]*$") or ""
end

local function isDir(path)
  local st = fstat(path)
  return st ~= nil and math.floor(st.attrib / 16) % 2 == 1 -- AM_DIR = 0x10
end

-- radio settings and model index files are never sent or overwritten
local function isProtected(p)
  local u = string.upper(p)
  return string.sub(u, 1, 7) == "/RADIO/" or u == "/MODELS/MODELS.YML" or u == "/MODELS/LABELS.YML"
end

local function listDir(path)
  local dirs, files = {}, {}
  for name in dir(path) do
    if string.sub(name, 1, 1) ~= "." and name ~= "System Volume Information" then
      local p = join(path, name)
      if isDir(p) then
        dirs[#dirs + 1] = name
      else
        local st = fstat(p)
        files[#files + 1] = { name = name, size = st and st.size or 0 }
      end
    end
  end
  table.sort(dirs)
  table.sort(files, function(a, b) return a.name < b.name end)
  return dirs, files
end

local function makeDirs(path)
  local d = ""
  for part in string.gmatch(parent(path), "[^/]+") do
    d = d .. "/" .. part
    if not fstat(d) then
      if not mkdir then return false end
      mkdir(d)
      if not fstat(d) then return false end
    end
  end
  return true
end

local function readHead(path, n)
  local f = io.open(path, "r")
  if not f then return "" end
  local s = io.read(f, n) or ""
  io.close(f)
  return s
end

local function freeModelName()
  for i = 1, 999 do
    local p = string.format("/MODELS/model%02d.yml", i)
    if not fstat(p) then return p end
  end
end

local function fmtSize(n)
  if n >= 1024 * 1024 then return string.format("%.1f MB", n / 1048576) end
  if n >= 1024 then return string.format("%.1f KB", n / 1024) end
  return n .. " B"
end

local function readAll(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local parts = {}
  while true do
    local s = io.read(f, 1024)
    if not s or #s == 0 then break end
    parts[#parts + 1] = s
  end
  io.close(f)
  return table.concat(parts)
end

-- Looks in the saved radio settings (read only) for a serial port in LUA mode.
-- The radio saves setting changes a moment later, so the result can lag behind.
local function checkPorts()
  local s = readAll("/RADIO/radio.yml")
  if not s then
    portText, portCol = "Port check: radio settings not found", COL_WARN
    return
  end
  local inSection, port, luaPorts = false, nil, {}
  for line in string.gmatch(s, "[^\r\n]+") do
    if string.match(line, "^serialPort:") then
      inSection = true
    elseif inSection then
      if not string.match(line, "^%s") then break end -- next top level setting
      port = string.match(line, "^%s+([%w_]+):%s*$") or port
      local mode = string.match(line, "mode:%s*([%w_]+)")
      if mode and port and string.find(mode, "LUA", 1, true) then luaPorts[#luaPorts + 1] = port end
    end
  end
  if #luaPorts > 0 then
    portText, portCol = "Serial " .. table.concat(luaPorts, ", ") .. " = LUA", COL_OK
  else
    portText, portCol = "No serial port set to LUA!", COL_ERR
  end
end

-- Reads the trainer mode of the active model from its file (read only).
-- Lua has no function for it. Stays nil when the file layout is not recognised.
local function detectTrainerRole()
  trainerRole = nil
  local file
  if model and model.getInfo then
    local info = model.getInfo()
    file = info and info.filename
  end
  if not file then
    local s = readAll("/RADIO/radio.yml")
    file = s and string.match(s, 'currModelFilename:%s*"?([^"\r\n]+)')
  end
  if not file then return end
  file = string.match(file, "^%s*(.-)%s*$")
  local s = readAll("/MODELS/" .. file)
  if not s then return end
  -- the radio leaves default settings out of the file: no trainer section means Off
  trainerRole = "off"
  local inSection = false
  for line in string.gmatch(s, "[^\r\n]+") do
    if string.match(line, "^trainerData:") then
      inSection = true
    elseif inSection then
      if not string.match(line, "^%s") then break end -- next top level setting
      local mode = string.match(line, "^%s+mode:%s*(%S+)")
      if mode then
        local u = string.upper(mode)
        local other = string.find(u, "BLUETOOTH", 1, true) or string.find(u, "MODULE", 1, true)
          or string.find(u, "SBUS", 1, true) or string.find(u, "CPPM", 1, true) or string.find(u, "MULTI", 1, true)
        if other then
          trainerRole = "off"
        elseif string.find(u, "SLAVE", 1, true) then
          trainerRole = "slave"
        elseif string.find(u, "MASTER", 1, true) then
          trainerRole = "master"
        end
      end
    end
  end
end

---------------------------------------------------------------------------
-- Serial link: packet = type(1) seq(1) payload checksum(2), SLIP framed
---------------------------------------------------------------------------

local function sendPacket(t, seq, payload)
  local raw = t .. string.char(seq) .. (payload or "")
  raw = raw .. string.char(fletcher(raw))
  serialWrite(END .. string.gsub(raw, "[\192\219]", SLIP_ENC) .. END)
end

local function pollSerial()
  for _ = 1, 4 do
    local d = serialRead(256)
    if not d or #d == 0 then break end
    rxBuf = rxBuf .. d
  end
end

-- returns type, seq, payload of the next valid packet in the buffer, or nil
local function nextPacket()
  while true do
    local p = string.find(rxBuf, END, 1, true)
    if not p then
      if #rxBuf > 2048 then rxBuf = "" end
      return nil
    end
    local frame = string.sub(rxBuf, 1, p - 1)
    rxBuf = string.sub(rxBuf, p + 1)
    if #frame >= 4 then
      frame = string.gsub(frame, ESC .. "(.)", SLIP_DEC)
      local body = string.sub(frame, 1, -3)
      local a, b = fletcher(body)
      if a == string.byte(frame, -2) and b == string.byte(frame, -1) then
        return string.sub(body, 1, 1), string.byte(body, 2), string.sub(body, 3)
      end
    end
  end
end

---------------------------------------------------------------------------
-- Online state and echo: "P" = I am here, "T" = echo request, "R" = echo reply
---------------------------------------------------------------------------

local function sendPing()
  if getTime() - lastPing >= PING_EVERY then
    lastPing = getTime()
    sendPacket("P", 0, PROTO .. "|" .. myRadio)
  end
end

-- every valid packet proves the other radio is there.
-- Returns true when the packet was a ping or echo and is handled.
local function linkPacket(t, seq, p)
  peerTime = getTime()
  if t == "P" then
    peerProto, peerRadio = string.match(p, "^([^|]*)|?(.*)$")
    return true
  elseif t == "T" then
    sendPacket("R", seq, p)
    return true
  end
  return false
end

local function peerOnline()
  return getTime() - peerTime < ONLINE_FOR
end

---------------------------------------------------------------------------
-- Screens: switching and the "done" summary
---------------------------------------------------------------------------

local function show(s)
  state = s
  listSel, listTop, followSel = 1, 1, true
  rowH = (s == "menu" or s == "ttest") and ROW_DESC or ROW_H
  if s == "menu" then
    checkPorts()
    detectTrainerRole()
  end
end

local function finish(title, ok, lines)
  doneTitle, doneOk, doneLines = title, ok, lines
  show("done")
end

---------------------------------------------------------------------------
-- Sender
---------------------------------------------------------------------------

local function txPacket(t, payload)
  tx.seq = (tx.seq + 1) % 256
  tx.t, tx.p = t, payload or ""
  tx.retry, tx.time = 0, getTime()
  sendPacket(tx.t, tx.seq, tx.p)
end

local function txSummary()
  return {
    string.format("Sent: %d   Skipped: %d   Failed: %d", tx.ok, tx.skip, tx.fail),
    tx.lastErr and ("Last problem: " .. tx.lastErr) or "",
  }
end

local function txAbort(reason)
  if tx.f then io.close(tx.f); tx.f = nil end
  local lines = txSummary()
  table.insert(lines, 1, reason)
  finish("Transfer aborted", false, lines)
end

local function txNextFile()
  if tx.f then io.close(tx.f); tx.f = nil end
  while true do
    tx.idx = tx.idx + 1
    local q = tx.queue[tx.idx]
    if not q then
      tx.cur = nil
      tx.phase = "bye"
      txPacket("Z")
      return
    end
    tx.f = io.open(q.src, "r")
    if tx.f then
      tx.cur, tx.off, tx.ca, tx.cb = q, 0, 0, 0
      tx.phase = "fstart"
      txPacket("F", q.kind .. "|" .. q.size .. "|" .. q.dst)
      return
    end
    tx.fail = tx.fail + 1
    tx.lastErr = "cannot read " .. q.src
  end
end

local function txChunk()
  local data = io.read(tx.f, CHUNK) or ""
  if #data == 0 then
    io.close(tx.f); tx.f = nil
    tx.phase = "fend"
    txPacket("E", tx.ca .. "," .. tx.cb)
  else
    tx.ca, tx.cb = fletcher(data, tx.ca, tx.cb)
    tx.off = tx.off + #data
    tx.phase = "data"
    txPacket("D", data)
  end
end

local function txReply(t, p)
  local ok = (t == "A")
  if tx.phase == "hello" then
    if ok then txNextFile() else txAbort("Receiver: " .. p) end
  elseif tx.phase == "fstart" then
    if ok then
      txChunk()
    else
      if p == "exists" then tx.skip = tx.skip + 1 else tx.fail = tx.fail + 1 end
      tx.lastErr = tx.cur.dst .. ": " .. p
      txNextFile()
    end
  elseif tx.phase == "data" then
    if ok then
      txChunk()
    else
      tx.fail = tx.fail + 1
      tx.lastErr = tx.cur.dst .. ": " .. p
      txNextFile()
    end
  elseif tx.phase == "fend" then
    if ok then
      tx.ok = tx.ok + 1
    else
      tx.fail = tx.fail + 1
      tx.lastErr = tx.cur.dst .. ": " .. p
    end
    txNextFile()
  elseif tx.phase == "bye" then
    finish("Transfer complete", tx.fail == 0, txSummary())
  end
end

local function txTick()
  pollSerial()
  local t, seq, p = nextPacket()
  while t do
    peerTime = getTime()
    if seq == tx.seq and (t == "A" or t == "N") then txReply(t, p) end
    if state ~= "send" then return end
    t, seq, p = nextPacket()
  end
  if getTime() - tx.time > TIMEOUT then
    if tx.phase ~= "hello" then -- waiting for the receiver has no limit
      tx.retry = tx.retry + 1
      if tx.retry > MAX_RETRY then
        -- all files are confirmed already, only the final "done" reply was lost
        if tx.phase == "bye" then return finish("Transfer complete", tx.fail == 0, txSummary()) end
        return txAbort("No answer from the receiver")
      end
    end
    tx.time = getTime()
    sendPacket(tx.t, tx.seq, tx.p)
  end
end

local function startSend(queue)
  if #queue == 0 then
    return finish("Nothing to send", false, { "The selection contains no files." })
  end
  if link == "trainer" then return tStartSend(queue) end
  local total = 0
  for _, q in ipairs(queue) do total = total + q.size end
  rxBuf = ""
  tx = { queue = queue, idx = 0, seq = 0, total = total, ok = 0, skip = 0, fail = 0, off = 0, start = getTime() }
  show("send")
  tx.phase = "hello"
  txPacket("H", PROTO)
end

local function sendModel(m)
  local src = "/MODELS/" .. m.file
  local st = fstat(src)
  local queue = { { src = src, dst = m.file, kind = "M", size = st and st.size or 0 } }
  -- send the model image along, the receiver keeps its own copy if it has one
  local bmp = string.match(readHead(src, 1024), 'bitmap:%s*"([^"]+)"')
  if bmp then
    local img = "/IMAGES/" .. bmp
    local ist = fstat(img)
    if ist then queue[2] = { src = img, dst = img, kind = "F", size = ist.size } end
  end
  startSend(queue)
end

local function sendFile(path, size)
  startSend({ { src = path, dst = path, kind = "F", size = size } })
end

-- folders are scanned one directory per cycle to stay below the script CPU limit
local function scanTick()
  local path = table.remove(scan.stack)
  if not path then return startSend(scan.queue) end
  local dirs, files = listDir(path)
  for _, d in ipairs(dirs) do
    local p = join(path, d)
    if not isProtected(p .. "/") then scan.stack[#scan.stack + 1] = p end
  end
  for _, f in ipairs(files) do
    local p = join(path, f.name)
    if not isProtected(p) then
      scan.queue[#scan.queue + 1] = { src = p, dst = p, kind = "F", size = f.size }
    end
  end
end

---------------------------------------------------------------------------
-- Receiver
---------------------------------------------------------------------------

local function rxReply(seq, t, p)
  rx.lastSeq, rx.lastT, rx.lastP = seq, t, p or ""
  sendPacket(t, seq, rx.lastP)
end

local function rxDropPartial()
  if rx.f then
    io.close(rx.f); rx.f = nil
    if del then del(rx.path) end
  end
end

local function rxFail(seq, reason)
  rx.fail = rx.fail + 1
  rx.lastErr = (rx.path or "?") .. ": " .. reason
  rxReply(seq, "N", reason)
end

local function rxPacket(t, seq, p)
  -- a repeated packet means our reply got lost: answer again, do not process twice
  if t ~= "H" and seq == rx.lastSeq then return sendPacket(rx.lastT, seq, rx.lastP) end

  if t == "H" then
    rxDropPartial()
    if p ~= PROTO then return rxReply(seq, "N", "version " .. p .. ", need " .. PROTO) end
    rx.ok, rx.skip, rx.fail, rx.models, rx.lastErr = 0, 0, 0, 0, nil
    rx.status, rx.path, rx.size, rx.got = "Connected", nil, 0, 0
    rxReply(seq, "A")

  elseif t == "F" then
    rxDropPartial()
    local kind, size, path = string.match(p, "^(%a)|(%d+)|(.+)$")
    rx.path = path
    if not kind then return rxFail(seq, "bad header") end
    if kind == "M" then
      path = freeModelName()
      if not path then return rxFail(seq, "no free model slot") end
    else
      if string.sub(path, 1, 1) ~= "/" or string.find(path, "..", 1, true) or isProtected(path) then
        return rxFail(seq, "path not allowed")
      end
      if fstat(path) and not overwrite then
        rx.skip = rx.skip + 1
        return rxReply(seq, "N", "exists")
      end
    end
    rx.path = path
    if not makeDirs(path) then return rxFail(seq, "cannot create folder") end
    rx.f = io.open(path, "w")
    if not rx.f then return rxFail(seq, "cannot write") end
    rx.kind, rx.size, rx.got, rx.ca, rx.cb = kind, tonumber(size), 0, 0, 0
    rx.status = "Receiving"
    rxReply(seq, "A")

  elseif t == "D" then
    if not rx.f then return rxReply(seq, "N", "no file open") end
    io.write(rx.f, p)
    rx.ca, rx.cb = fletcher(p, rx.ca, rx.cb)
    rx.got = rx.got + #p
    rxReply(seq, "A")

  elseif t == "E" then
    if not rx.f then return rxReply(seq, "N", "no file open") end
    io.close(rx.f); rx.f = nil
    if rx.got == rx.size and p == rx.ca .. "," .. rx.cb then
      rx.ok = rx.ok + 1
      if rx.kind == "M" then rx.models = rx.models + 1 end
      rxReply(seq, "A")
    else
      if del then del(rx.path) end
      rxFail(seq, "checksum error")
    end

  elseif t == "Z" then
    rxReply(seq, "A")
    rx.status = "Finished"
    local lines = { string.format("Received: %d   Skipped: %d   Failed: %d", rx.ok, rx.skip, rx.fail) }
    if rx.models > 0 then lines[#lines + 1] = "Restart the radio to see the new model." end
    if rx.lastErr then lines[#lines + 1] = "Last problem: " .. rx.lastErr end
    finish("Receive complete", rx.fail == 0, lines)
  end
end

local function rxTick()
  pollSerial()
  local t, seq, p = nextPacket()
  while t do
    if not linkPacket(t, seq, p) then rxPacket(t, seq, p) end
    if state ~= "recv" then return end
    t, seq, p = nextPacket()
  end
end

local function startReceive()
  if link == "trainer" then return tStartReceive() end
  rxBuf = ""
  rx = { status = "Waiting for sender...", ok = 0, skip = 0, fail = 0, models = 0, size = 0, got = 0 }
  show("recv")
end

---------------------------------------------------------------------------
-- Connection test and idle link handling
---------------------------------------------------------------------------

local function startTest()
  rxBuf = ""
  test = { n = 0, ok = 0, lost = 0, rttSum = 0, rttMax = 0, seq = 0 }
  show("test")
end

local function testReply(seq, p)
  if test.waiting and seq == test.seq and p == test.payload then
    local rtt = (getTime() - test.sentAt) * 10
    test.ok = test.ok + 1
    test.rttSum = test.rttSum + rtt
    test.rttMax = math.max(test.rttMax, rtt)
    test.waiting = false
  end
end

local function testTick()
  if test.waiting and getTime() - test.sentAt > TIMEOUT then
    test.lost = test.lost + 1
    test.waiting = false
  end
  if not test.waiting and test.n < TEST_ROUNDS then
    test.n = test.n + 1
    test.seq = test.n
    local bytes = {}
    for i = 1, 48 do bytes[i] = string.char((i * 37 + test.n * 11) % 256) end
    -- the framing bytes are included on purpose, they must survive the trip too
    test.payload = table.concat(bytes) .. END .. ESC
    test.waiting, test.sentAt = true, getTime()
    sendPacket("T", test.seq, test.payload)
  end
end

-- on all screens without a transfer: answer pings and echoes, notice a waiting sender
local function idleTick()
  pollSerial()
  local t, seq, p = nextPacket()
  while t do
    if not linkPacket(t, seq, p) then
      if t == "H" then
        peerSending = getTime()
      elseif t == "R" and state == "test" then
        testReply(seq, p)
      end
    end
    t, seq, p = nextPacket()
  end
end

---------------------------------------------------------------------------
-- Trainer link: one way, the data rides on the channel values.
-- One symbol = CH1-CH7 seven 6 bit digits and CH8 = clock (+/-T_CLK, flips with every
-- symbol). The digits carry 5 bytes, a flag for the first symbol of a packet, and a copy
-- of the clock in the top bit of CH1.
-- The clock is the last channel on purpose: it is written last on the sender and
-- arrives last in a PPM frame, so a new clock value means CH1-CH7 are new as well.
-- If the receiver reads while the next frame is half received, CH1 already belongs
-- to the next symbol and its clock bit no longer matches CH8: that read is skipped.
-- Packet: len(1) type(1) body checksum(2), padded to whole symbols.
-- The sender repeats all files in rounds, the receiver collects what it is missing.
---------------------------------------------------------------------------

local T_STEP = 2 * T_RANGE / 63

local function digitValue(d)
  return -T_RANGE + d * T_STEP
end

local function u16(n)
  return string.char(math.floor(n / 256) % 256, n % 256)
end

local function u24(n)
  return string.char(math.floor(n / 65536) % 256, math.floor(n / 256) % 256, n % 256)
end

local function tPacket(body)
  local raw = string.char(#body + 3) .. body
  raw = raw .. string.char(fletcher(raw))
  while #raw % 5 ~= 0 do raw = raw .. "\0" end
  return raw
end

-- 5 bytes + first flag + clock bit -> 7 digits for CH1-CH7.
-- Every number stays below 2^24, safe for any Lua number type.
local function encodeSymbol(s, first, clockUp)
  local b1, b2, b3, b4, b5 = string.byte(s, 1, 5)
  local x = (b1 * 256 + b2) * 256 + b3
  local y = (first and 65536 or 0) + b4 * 256 + b5
  return {
    y % 32 + (clockUp and 32 or 0),
    math.floor(x / 262144), math.floor(x / 4096) % 64, math.floor(x / 64) % 64, x % 64,
    math.floor(y / 2048), math.floor(y / 32) % 64,
  }
end

-- 7 digits -> 5 bytes and the first-symbol flag
local function decodeSymbol(d)
  local x = ((d[2] * 64 + d[3]) * 64 + d[4]) * 64 + d[5]
  local y = (d[6] * 64 + d[7]) * 32 + d[1] % 32
  local first = y >= 65536
  y = y % 65536
  return string.char(math.floor(x / 65536), math.floor(x / 256) % 256, x % 256,
    math.floor(y / 256), y % 256), first
end

-- sender model: mixes CH1-CH8 = GV1-GV8, RF modules off

local function gvSource(n)
  local fi = getFieldInfo("gvar" .. n) or getFieldInfo("GV" .. n)
  return fi and fi.id
end

local function mixesMissing()
  local missing = {}
  for ch = 0, 7 do
    local found = false
    for i = 0, model.getMixesCount(ch) - 1 do
      local m = model.getMix(ch, i)
      if m and m.name and string.find(m.name, MIX_NAME, 1, true) then found = true end
    end
    if not found then missing[#missing + 1] = ch end
  end
  return missing
end

local function addMixes()
  for _, ch in ipairs(mixesMissing()) do
    local src = gvSource(ch + 1)
    if not src then return end
    -- appended last with "Replace", so it overrides the sticks on this channel
    model.insertMix(ch, model.getMixesCount(ch), { name = MIX_NAME, source = src, weight = 100, multiplex = 2 })
  end
end

local function rfActive()
  if not model.getModule then return false end
  for i = 0, 1 do
    local m = model.getModule(i)
    if m and m.Type and m.Type ~= 0 then return true end
  end
  return false
end

-- data channels first, then CH1 with the clock bit, the clock (CH8) last,
-- so a half updated symbol never shows a new clock
local function setGVs(vals)
  local fm = getFlightMode and getFlightMode() or 0
  for _, i in ipairs({ 2, 3, 4, 5, 6, 7, 1, 8 }) do
    local v = math.floor((vals[i] or 0) / ts.scale + 0.5)
    model.setGlobalVariable(i - 1, fm, math.max(-1024, math.min(1024, v)))
  end
end

-- sender

-- pattern = true sends the test signal of the connection test instead of files
tStartSend = function(queue, pattern)
  while #queue > 255 do table.remove(queue) end
  ts = { queue = queue, phase = "check", scale = 1, sid = getTime() % 255 + 1, round = 1, fi = 1,
         pkt = "", pos = 1, clock = 1, symTime = 0, prepIdx = 1, syms = 0, startTime = 0, skipped = 0,
         pattern = pattern, k = 0, hold = T_SPEEDS[tSpeed].hold }
  show("tsend")
end

-- test signal: CH1 counts 0..31 (plus the clock bit), the other channels follow from the count
local function patternDigit(k, i)
  if i == 1 then return k end
  return (k * 5 + i * 13) % 64
end

local function tsNextPacket()
  for _ = 1, 2 * #ts.queue + 2 do
    local q = ts.queue[ts.fi]
    if not q then
      ts.fi, ts.round = 1, ts.round + 1
    elseif not ts.ci then
      ts.ci = 0
      ts.f = io.open(q.src, "r")
      return tPacket("F" .. string.char(ts.sid, ts.fi, #ts.queue) .. q.kind .. u24(q.size)
        .. string.char(q.fa, q.fb) .. q.dst)
    else
      local data = ts.f and io.read(ts.f, T_CHUNK) or ""
      if #data > 0 then
        ts.ci = ts.ci + 1
        return tPacket("D" .. string.char(ts.sid, ts.fi) .. u16(ts.ci - 1) .. data)
      end
      if ts.f then io.close(ts.f); ts.f = nil end
      ts.ci, ts.fi = nil, ts.fi + 1
    end
  end
end

local function tsNextSymbol()
  ts.clock = -ts.clock
  local up = ts.clock > 0
  local d
  if ts.pattern then
    ts.k = (ts.k + 1) % 32
    d = {}
    for i = 1, 7 do d[i] = patternDigit(ts.k, i) end
    d[1] = d[1] + (up and 32 or 0)
  else
    if ts.pos > #ts.pkt then ts.pkt, ts.pos = tsNextPacket(), 1 end
    d = encodeSymbol(string.sub(ts.pkt, ts.pos, ts.pos + 4), ts.pos == 1, up)
    ts.pos = ts.pos + 5
  end
  local vals = {}
  for i = 1, 7 do vals[i] = digitValue(d[i]) end
  vals[8] = ts.clock * T_CLK
  setGVs(vals)
  ts.syms = ts.syms + 1
end

local function tsStop()
  if ts.f then io.close(ts.f); ts.f = nil end
  local q = ts.queue[ts.prepIdx]
  if q and q.pf then io.close(q.pf); q.pf = nil end
  if ts.phase == "scale" or ts.phase == "prep" or ts.phase == "run" then setGVs({}) end
end

local function tsTick()
  local now = getTime()
  if ts.phase == "check" then
    ts.rf, ts.missing = rfActive(), #mixesMissing()
    if not ts.rf and ts.missing == 0 then
      ts.phase, ts.t0 = "scale", now
      setGVs({ 80 }) -- small, so it is not clipped if the radio treats GVs as percent
    end

  elseif ts.phase == "scale" then
    -- measure how a GV value arrives on CH1, so the levels on the cable are right
    if now - ts.t0 >= 20 then
      local out = getOutputValue and getOutputValue(0)
      if out then
        if math.abs(out) < 20 then ts.phase = "nomix"; return end
        ts.scale = out / 80
      end
      ts.phase = "prep"
    end

  elseif ts.phase == "prep" then
    if ts.pattern then
      ts.phase, ts.startTime, ts.symTime = "run", now, now - ts.hold
      return
    end
    -- file checksums, 1 KB per cycle
    local q = ts.queue[ts.prepIdx]
    if not q then
      local list = {}
      for _, e in ipairs(ts.queue) do
        if not e.skip then list[#list + 1] = e end
      end
      ts.skipped, ts.queue = #ts.queue - #list, list
      if #list == 0 then
        tsStop()
        return finish("Nothing to send", false, { "Files over " .. fmtSize(T_MAX_FILE) .. " are too slow for the trainer cable." })
      end
      ts.phase, ts.startTime, ts.symTime = "run", now, now - ts.hold
      return
    end
    if not q.pf then
      if q.size > T_MAX_FILE or #q.dst > 200 then q.skip = true end
      if not q.skip then q.pf = io.open(q.src, "r") end
      if not q.pf then q.skip = true; ts.prepIdx = ts.prepIdx + 1; return end
      q.fa, q.fb = 0, 0
    end
    local s = io.read(q.pf, 1024) or ""
    if #s == 0 then
      io.close(q.pf); q.pf = nil
      ts.prepIdx = ts.prepIdx + 1
    else
      q.fa, q.fb = fletcher(s, q.fa, q.fb)
    end

  elseif ts.phase == "run" then
    if now - ts.symTime >= ts.hold then
      -- recent step time, follows a speed change within a few steps
      ts.stepAvg = ts.stepAvg and (ts.stepAvg * 0.8 + (now - ts.symTime) * 0.2) or ts.hold
      ts.symTime = now
      tsNextSymbol()
    end
  end
end

-- receiver

local trIds = {}

tStartReceive = function(pattern)
  for i = 1, 8 do
    local fi = getFieldInfo("TR" .. i) or getFieldInfo("trn" .. i)
    trIds[i] = fi and fi.id
  end
  if not trIds[8] then
    return finish("Trainer inputs not found", false, { "This radio offers no TR1 - TR8 sources to Lua." })
  end
  tr = { hi = T_CLK, lo = -T_CLK, lastSign = 0, good = 0, bad = 0, syms = 0,
         sigTime = -1000, files = {}, ready = {}, ok = 0, skip = 0, fail = 0, models = 0, raw = {},
         pattern = pattern, lastRun = getTime(), runs = 0, runSum = 0, runMax = 0, firstSym = nil,
         missed = 0, errSyms = 0, maxDev = 0, counted = 0, torn = 0, goodTime = -1000 }
  show("trecv")
end

-- connection test: compares a received test symbol with what it must be
local function trPatternSymbol(d, vals)
  local k = d[1] % 32
  -- the first symbols only lock on to the clock levels and are not counted
  if tr.syms <= 8 then
    tr.lastK, tr.counted = k, 0
    return
  end
  tr.counted = tr.counted + 1
  local inSequence = (k - tr.lastK - 1) % 32
  tr.lastK = k
  local wrong = false
  for i = 1, 7 do
    local e = (i == 1) and d[1] or patternDigit(k, i)
    if d[i] ~= e then wrong = true end
    -- only meaningful when the counter itself fits the sequence
    if inSequence < 8 then tr.maxDev = math.max(tr.maxDev, math.abs(vals[i] - digitValue(e))) end
  end
  if wrong then
    tr.errSyms = tr.errSyms + 1
  else
    tr.missed = tr.missed + inSequence
    tr.goodTime = getTime()
  end
end

local function trDropFin()
  local f = tr.fin
  if f and f.h then
    io.close(f.h); f.h = nil
    if del then del(f.dest) end
  end
  tr.fin = nil
end

local function trSession(sid)
  if sid ~= tr.sid then
    trDropFin()
    tr.sid, tr.files, tr.nFiles, tr.ready = sid, {}, nil, {}
    tr.ok, tr.skip, tr.fail, tr.models, tr.lastErr = 0, 0, 0, 0, nil
  end
end

local function trFile(n)
  local f = tr.files[n]
  if not f then
    f = { chunks = {}, count = 0 }
    tr.files[n] = f
  end
  return f
end

local function trFailFile(f, reason)
  f.done, f.chunks = true, nil
  tr.fail = tr.fail + 1
  tr.lastErr = (f.path or "?") .. ": " .. reason
end

local function trCheckReady(f)
  if f.need and not f.done and not f.queued and f.count >= f.need then
    f.queued = true
    tr.ready[#tr.ready + 1] = f
  end
end

local function trBody(body)
  local t = string.sub(body, 1, 1)
  if t == "F" and #body >= 10 then
    local sid, n, nf = string.byte(body, 2, 4)
    trSession(sid)
    tr.nFiles = nf
    local f = trFile(n)
    if f.need then return end -- header already known
    local s1, s2, s3, fa, fb = string.byte(body, 6, 10)
    f.kind, f.fa, f.fb, f.path = string.sub(body, 5, 5), fa, fb, string.sub(body, 11)
    f.size = (s1 * 256 + s2) * 256 + s3
    f.need = math.ceil(f.size / T_CHUNK)
    if f.kind ~= "M" then
      if string.sub(f.path, 1, 1) ~= "/" or string.find(f.path, "..", 1, true) or isProtected(f.path) then
        return trFailFile(f, "path not allowed")
      end
      if fstat(f.path) and not overwrite then
        f.done, f.chunks = true, nil
        tr.skip = tr.skip + 1
        return
      end
    end
    trCheckReady(f)
  elseif t == "D" and #body >= 6 then
    local sid, n, i1, i2 = string.byte(body, 2, 5)
    trSession(sid)
    local f = trFile(n)
    if f.done then return end
    local idx = i1 * 256 + i2
    if not f.chunks[idx] then
      f.chunks[idx] = string.sub(body, 6)
      f.count = f.count + 1
    end
    trCheckReady(f)
  end
end

-- writes a complete file to the SD card, 50 chunks per cycle
local function trFinalize()
  local f = tr.fin
  if not f then
    f = table.remove(tr.ready, 1)
    if not f then return end
    local path = f.path
    if f.kind == "M" then path = freeModelName() end
    if not path then return trFailFile(f, "no free model slot") end
    if not makeDirs(path) then return trFailFile(f, "cannot create folder") end
    f.h = io.open(path, "w")
    if not f.h then return trFailFile(f, "cannot write") end
    f.dest, f.wi, f.wa, f.wb, f.wlen = path, 0, 0, 0, 0
    tr.fin = f
  end
  for _ = 1, 50 do
    if f.wi >= f.need then
      io.close(f.h); f.h = nil
      tr.fin = nil
      if f.wlen == f.size and f.wa == f.fa and f.wb == f.fb then
        f.done, f.chunks = true, nil
        tr.ok = tr.ok + 1
        if f.kind == "M" then tr.models = tr.models + 1 end
      else
        if del then del(f.dest) end
        f.chunks, f.count, f.queued = {}, 0, false -- collect it again in the next round
        tr.lastErr = f.path .. ": checksum error, receiving again"
      end
      return
    end
    local c = f.chunks[f.wi]
    if not c then -- impossible chunk numbers filled the count, start this file over
      trDropFin()
      f.chunks, f.count, f.queued = {}, 0, false
      return
    end
    io.write(f.h, c)
    f.wa, f.wb = fletcher(c, f.wa, f.wb)
    f.wlen = f.wlen + #c
    f.wi = f.wi + 1
  end
end

local function trSymbol(bytes, first)
  if first then
    tr.buf = bytes
  elseif tr.buf then
    tr.buf = tr.buf .. bytes
  else
    return
  end
  local len = string.byte(tr.buf, 1)
  if len < 4 then
    tr.buf = nil
    tr.bad = tr.bad + 1
  elseif #tr.buf >= len then
    local pkt = string.sub(tr.buf, 1, len - 2)
    local a, b = fletcher(pkt)
    if a == string.byte(tr.buf, len - 1) and b == string.byte(tr.buf, len) then
      tr.good = tr.good + 1
      tr.goodTime = getTime()
      trBody(string.sub(pkt, 2))
    else
      tr.bad = tr.bad + 1
    end
    tr.buf = nil
  end
end

local function trTick()
  local now = getTime()
  -- how often this script gets to read the inputs
  local gap = now - tr.lastRun
  tr.lastRun = now
  if gap > 0 and gap < 100 then
    tr.runs, tr.runSum, tr.runMax = tr.runs + 1, tr.runSum + gap, math.max(tr.runMax, gap)
  end
  local raw = tr.raw
  for i = 1, 8 do raw[i] = getValue(trIds[i]) or 0 end

  -- the clock levels give gain and offset of the link
  local off, g = (tr.hi + tr.lo) / 2, (tr.hi - tr.lo) / (2 * T_CLK)
  if g < 0.2 then tr.hi, tr.lo = T_CLK, -T_CLK; return end
  local c = (raw[8] - off) / g
  if math.abs(c) >= T_CLK / 2 then
    tr.sigTime = now
    local sign = c > 0 and 1 or -1
    -- a symbol counts as soon as the clock flipped: CH8 arrives last in the frame,
    -- so CH1-CH7 already carry the new values
    if sign ~= tr.lastSign then
      local d, vals = {}, {}
      for i = 1, 7 do
        vals[i] = (raw[i] - off) / g
        d[i] = math.max(0, math.min(63, math.floor((vals[i] + T_RANGE) / T_STEP + 0.5)))
      end
      -- clock bit in CH1 must match CH8, otherwise this read caught the next frame half done
      if (d[1] >= 32) ~= (sign > 0) then
        tr.torn = tr.torn + 1
        return
      end
      tr.lastSign = sign
      tr.syms = tr.syms + 1
      -- take the first clock levels directly, then follow them slowly
      local a = tr.syms <= 4 and 1 or 0.2
      if sign > 0 then tr.hi = tr.hi * (1 - a) + raw[8] * a else tr.lo = tr.lo * (1 - a) + raw[8] * a end
      tr.firstSym = tr.firstSym or now
      if tr.pattern then
        trPatternSymbol(d, vals)
      else
        local bytes, first = decodeSymbol(d)
        if bytes then trSymbol(bytes, first) else tr.buf = nil end
      end
    end
  end

  if tr.pattern then return end
  trFinalize()

  if tr.nFiles and not tr.fin and #tr.ready == 0 then
    for n = 1, tr.nFiles do
      local f = tr.files[n]
      if not (f and f.done) then return end
    end
    local lines = { string.format("Received: %d   Skipped: %d   Failed: %d", tr.ok, tr.skip, tr.fail),
                    "You can stop the sender now." }
    if tr.models > 0 then lines[#lines + 1] = "Restart the radio to see the new model." end
    if tr.lastErr then lines[#lines + 1] = "Last problem: " .. tr.lastErr end
    finish("Receive complete", tr.fail == 0, lines)
  end
end

---------------------------------------------------------------------------
-- Drawing
---------------------------------------------------------------------------

local function region(id, x, y, w, h)
  regions[#regions + 1] = { id = id, x = x, y = y, w = w, h = h }
end

local function hitTest(x, y)
  for _, r in ipairs(lastRegions) do
    if x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h then return r.id end
  end
end

-- Turns touch events into the id of the tapped region.
-- EdgeTX ends a touch with TAP, BREAK or both, and drops events when several arrive
-- within one script cycle, so a touch counts on whichever end event comes first.
-- The region under the first contact counts: the position of the end event is not
-- reliable on every radio. A touch that moved more than DRAG pixels scrolls instead.
local function touchInput(event, st)
  local now = getTime()
  if event == EVT_TOUCH_FIRST then
    touch = { y0 = st.y, top = listTop, id = hitTest(st.x, st.y) }
    -- highlight the row right away, so the finger gets feedback
    if type(touch.id) == "number" then listSel = touch.id end
  elseif event == EVT_TOUCH_SLIDE then
    if not touch or touch.done then
      touch = { y0 = st.startY or st.y, top = listTop, id = st.startX and hitTest(st.startX, st.startY) }
    end
    local dy = st.y - touch.y0
    if math.abs(dy) > DRAG then touch.scroll = true end
    if touch.scroll then
      listTop = touch.top - math.floor(dy / rowH + 0.5) -- clamped when drawn
      followSel = false
    end
  elseif event == EVT_TOUCH_TAP or event == EVT_TOUCH_BREAK then
    if touch and touch.done then
      -- second end event of a touch that is handled already
      if now - touch.done < 30 then return end
      touch = nil
    end
    local id
    if touch then
      if not touch.scroll then id = touch.id end
    elseif event == EVT_TOUCH_TAP and st.x then
      id = hitTest(st.x, st.y) -- the start of this touch was dropped
    end
    touch = { done = now }
    return id
  end
end

local function drawButton(id, x, y, w, h, text, col)
  lcd.drawFilledRectangle(x, y, w, h, col or COL_BTN)
  lcd.drawText(x + math.floor(w / 2), y + math.floor(h / 2) - 10, text, CENTER + COL_TEXT)
  region(id, x, y, w, h)
end

local function drawHeader(title)
  lcd.clear(COL_BG)
  lcd.drawFilledRectangle(0, 0, LCD_W, BAR_H, COL_BAR)
  lcd.drawText(10, 8, title, MIDSIZE + COL_TEXT)
  drawButton("back", LCD_W - 50, 0, 50, BAR_H, "X")

  -- online state of the other radio
  local col, text = COL_ERR, "Offline"
  if link == "trainer" then
    -- one way: only the receiving side can tell whether data arrives
    if state == "tsend" then
      col, text = (ts.phase == "run") and COL_OK or COL_DIM, "Transmitter"
    elseif state ~= "trecv" then
      col = COL_DIM
      if trainerRole == "slave" then text = "Transmitter"
      elseif trainerRole == "master" then text = "Receiver"
      else text = "Trainer" end
    elseif getTime() - tr.goodTime < 500 then -- a packet can take a few seconds at slow speeds
      col, text = COL_OK, "Data"
    elseif getTime() - tr.sigTime < ONLINE_FOR then
      col, text = COL_WARN, "Signal"
    else
      col, text = COL_ERR, "No signal"
    end
  elseif peerOnline() then
    if peerProto and peerProto ~= PROTO then col, text = COL_WARN, "Version!" else col, text = COL_OK, "Online" end
  end
  local x, y = LCD_W - 165, math.floor(BAR_H / 2) -- room for "Transmitter" before the X
  if lcd.drawFilledCircle then
    lcd.drawFilledCircle(x, y, 7, col)
  else
    lcd.drawFilledRectangle(x - 7, y - 7, 14, 14, col)
  end
  lcd.drawText(x + 14, y - 10, text, COL_TEXT)
end

local function listRows()
  return math.floor((LCD_H - LIST_Y - BAR_H - 4) / rowH)
end

-- items: label, optional sub (right, dim), desc (second line, small), dim
local function drawList(items, footer, footerCol)
  local rows = listRows()
  if followSel then
    if listSel < listTop then listTop = listSel end
    if listSel >= listTop + rows then listTop = listSel - rows + 1 end
  end
  listTop = math.max(1, math.min(listTop, #items - rows + 1))
  for i = 0, rows - 1 do
    local idx = listTop + i
    local it = items[idx]
    if not it then break end
    local y = LIST_Y + i * rowH
    if idx == listSel then lcd.drawFilledRectangle(0, y, LCD_W, rowH, COL_SEL) end
    local ty = it.desc and y + 2 or y + 6
    lcd.drawText(12, ty, it.label, it.dim and COL_DIM or COL_TEXT)
    if it.sub then lcd.drawText(LCD_W - 12, ty, it.sub, RIGHT + COL_DIM) end
    if it.desc then lcd.drawText(12, y + 24, it.desc, SMLSIZE + COL_DIM) end
    region(idx, 0, y, LCD_W, rowH)
  end
  -- scroll bar on the right edge
  if #items > rows then
    local h = rows * rowH
    local th = math.max(16, math.floor(h * rows / #items))
    local ty = LIST_Y + math.floor((h - th) * (listTop - 1) / (#items - rows))
    lcd.drawFilledRectangle(LCD_W - 5, LIST_Y, 4, h, COL_BAR)
    lcd.drawFilledRectangle(LCD_W - 5, ty, 4, th, COL_DIM)
  end
  local by = LCD_H - BAR_H
  lcd.drawFilledRectangle(0, by, LCD_W, BAR_H, COL_BAR)
  if footer then lcd.drawText(10, by + 12, footer, footerCol or COL_DIM) end
  if #items > rows then
    drawButton("up", LCD_W - 140, by, 65, BAR_H, "Up")
    drawButton("down", LCD_W - 70, by, 70, BAR_H, "Dn")
  end
end

-- handles list navigation, returns the index of an activated entry
local function listInput(event, tap, n)
  if n == 0 then return end
  local rows = listRows()
  local step = (KEY_NEXT[event] and 1) or (KEY_PREV[event] and -1)
    or (KEY_PGDN[event] and rows) or (KEY_PGUP[event] and -rows)
  if step then
    if not followSel and (listSel < listTop or listSel >= listTop + rows) then
      listSel = listTop -- selection was swiped out of view: continue from the top row shown
    elseif step == 1 or step == -1 then
      listSel = (listSel - 1 + step) % n + 1
    else
      listSel = math.max(1, math.min(n, listSel + step))
    end
    followSel = true
  elseif event == EVT_VIRTUAL_ENTER then return listSel
  elseif tap == "up" or tap == "down" then
    listTop = math.max(1, math.min(n - rows + 1, listTop + (tap == "up" and -rows or rows)))
    listSel, followSel = listTop, true
  elseif type(tap) == "number" and tap <= n then listSel = tap; return tap
  end
end

local function drawProgress(y, frac)
  local w = LCD_W - 40
  lcd.drawRectangle(20, y, w, 20, COL_DIM)
  lcd.drawFilledRectangle(22, y + 2, math.floor((w - 4) * math.min(1, frac)), 16, COL_OK)
end

---------------------------------------------------------------------------
-- Screens
---------------------------------------------------------------------------

-- with the trainer cable the active model decides the direction:
-- returns whether this radio can send and receive, unknown allows both
local function trainerAllows()
  if link ~= "trainer" or not trainerRole then return true, true end
  return trainerRole == "slave", trainerRole == "master"
end

local function roleHint()
  if trainerRole == "slave" then return "Slave model: can only send" end
  if trainerRole == "master" then return "Master model: can only receive" end
  return "Trainer mode Off (Model Setup)"
end

local function menuItems()
  local trainer = link == "trainer"
  local canSend, canRecv = trainerAllows()
  local items = {
    { label = "Send model", desc = "Pick a model, it arrives as a new model on the other radio" },
    { label = "Send files / folder", desc = "Send any file or a whole folder from the SD card" },
    { label = "Receive", desc = "Wait for the other radio and save what it sends" },
    { label = "Connection test", desc = trainer and "Measure signal, timing and errors on the trainer cable"
      or "Check that the other radio answers over the serial port" },
    { label = "Overwrite existing files", sub = overwrite and "Yes" or "No",
      desc = "Receiving: replace files that already exist (models are always new)" },
    { label = "Connection", sub = trainer and "Trainer cable" or "Serial",
      desc = trainer and "3.5 mm trainer jacks, one way: Slave sends, Master receives"
      or "Serial port set to LUA on both radios, both ways" },
    { label = "Speed", sub = T_SPEEDS[tSpeed].name, dim = not trainer,
      desc = "Trainer cable, sending radio: slower is more reliable" },
  }
  -- sending: send entries and speed; receiving: receive and overwrite; Connection always works
  items[1].off, items[2].off, items[7].off = not canSend, not canSend, not canSend
  items[3].off, items[5].off = not canRecv, not canRecv
  items[4].off = not canSend and not canRecv
  for _, it in ipairs(items) do it.dim = it.dim or it.off end
  return items
end

local function openBrowser(path)
  cwd = path
  local dirs, files = listDir(path)
  browseItems = {}
  if path ~= "/" then browseItems[#browseItems + 1] = { label = "..", up = true } end
  browseItems[#browseItems + 1] = { label = "[ Send this whole folder ]" }
  for _, d in ipairs(dirs) do
    browseItems[#browseItems + 1] = { label = d .. "/", dir = d, dim = isProtected(join(path, d) .. "/") }
  end
  for _, f in ipairs(files) do
    browseItems[#browseItems + 1] = { label = f.name, file = f, sub = fmtSize(f.size), dim = isProtected(join(path, f.name)) }
  end
  show("browse")
end

local function openModels()
  models, nameIdx = {}, 1
  for name in dir("/MODELS") do
    local u = string.lower(name)
    if string.match(u, "%.yml$") and u ~= "models.yml" and u ~= "labels.yml" then
      models[#models + 1] = { file = name, label = name, sub = name }
    end
  end
  table.sort(models, function(a, b) return a.file < b.file end)
  show("models")
end

local screens = {}

screens.menu = function(event, tap)
  local items = menuItems()
  local act = listInput(event, tap, #items)
  if act and items[act].off then
    menuHint, menuHintTime = roleHint(), getTime()
    act = nil
  end
  if act == 1 then openModels()
  elseif act == 2 then openBrowser("/")
  elseif act == 3 then startReceive()
  elseif act == 4 then
    if link == "serial" then startTest() else show("ttest") end
  elseif act == 5 then overwrite = not overwrite
  elseif act == 6 then link = (link == "trainer") and "serial" or "trainer"
  elseif act == 7 then tSpeed = tSpeed % #T_SPEEDS + 1
  end
  if state ~= "menu" then return end
  drawHeader("Model Share")
  if link == "trainer" then
    if getTime() - menuHintTime < 300 then
      drawList(menuItems(), menuHint, COL_WARN)
    elseif trainerRole == "slave" then
      drawList(menuItems(), "This model: Slave/Jack, sends", COL_OK)
    elseif trainerRole == "master" then
      drawList(menuItems(), "This model: Master/Jack, receives", COL_OK)
    elseif trainerRole == "off" then
      drawList(menuItems(), "This model: Trainer mode Off", COL_ERR)
    else
      drawList(menuItems(), "Trainer cable: one way, sender = Slave", COL_DIM)
    end
  elseif getTime() - peerSending < ONLINE_FOR then
    drawList(menuItems(), "Other radio wants to send: tap Receive", COL_WARN)
  else
    drawList(menuItems(), portText, portCol)
  end
end

screens.ttest = function(event, tap)
  local canSend, canRecv = trainerAllows()
  local items = {
    { label = "Send test signal", desc = "On the sending radio (Trainer mode Slave/Jack)", off = not canSend },
    { label = "Receive test signal", desc = "On the receiving radio (Trainer mode Master/Jack)", off = not canRecv },
  }
  for _, it in ipairs(items) do it.dim = it.off end
  local act = listInput(event, tap, #items)
  if act and items[act].off then
    menuHint, menuHintTime = roleHint(), getTime()
    act = nil
  end
  if act == 1 then return tStartSend({}, true) end
  if act == 2 then return tStartReceive(true) end
  drawHeader("Connection test")
  if getTime() - menuHintTime < 300 then
    drawList(items, menuHint, COL_WARN)
  else
    drawList(items, "Start it on both radios", COL_DIM)
  end
end

screens.models = function(event, tap)
  -- read model names a few at a time
  for _ = 1, 4 do
    local m = models[nameIdx]
    if not m then break end
    local name = string.match(readHead("/MODELS/" .. m.file, 300), 'name:%s*"([^"]*)"')
    if name and name ~= "" then m.label = name end
    nameIdx = nameIdx + 1
  end
  local act = listInput(event, tap, #models)
  if act then return sendModel(models[act]) end
  drawHeader("Send model")
  if #models == 0 then lcd.drawText(12, LIST_Y + 6, "No models found in /MODELS", COL_DIM) end
  drawList(models, "Tap a model to send it")
end

screens.browse = function(event, tap)
  local act = listInput(event, tap, #browseItems)
  if act then
    local it = browseItems[act]
    if it.up then return openBrowser(parent(cwd) == "" and "/" or parent(cwd)) end
    if it.dim then return end
    if it.dir then return openBrowser(join(cwd, it.dir)) end
    if it.file then return sendFile(join(cwd, it.file.name), it.file.size) end
    scan = { stack = { cwd }, queue = {} }
    return show("scan")
  end
  drawHeader("Send files")
  drawList(browseItems, cwd)
end

screens.scan = function()
  scanTick()
  if state ~= "scan" then return end
  drawHeader("Send files")
  lcd.drawText(20, LIST_Y + 20, "Scanning folder...", COL_TEXT)
  lcd.drawText(20, LIST_Y + 50, #scan.queue .. " files found", COL_DIM)
end

screens.send = function()
  txTick()
  if state ~= "send" then return end
  drawHeader("Sending")
  local y = LIST_Y + 10
  if tx.phase == "hello" then
    lcd.drawText(20, y, "Waiting for receiver...", COL_TEXT)
    lcd.drawText(20, y + 30, "Start \"Receive\" on the other radio.", COL_DIM)
    if peerOnline() then
      lcd.drawText(20, y + 70, "The other radio is online.", COL_OK)
    elseif getTime() - tx.start > 300 then
      lcd.drawText(20, y + 70, "No answer. Please check:", COL_WARN)
      lcd.drawText(20, y + 98, "- Model Share open on the other radio?", COL_DIM)
      lcd.drawText(20, y + 124, "- Serial port set to LUA on both radios?", COL_DIM)
      lcd.drawText(20, y + 150, "- Cable crossed: TX -> RX, RX -> TX, GND?", COL_DIM)
    end
    return
  end
  lcd.drawText(20, y, string.format("File %d of %d", math.min(tx.idx, #tx.queue), #tx.queue), COL_TEXT)
  if tx.cur then
    lcd.drawText(20, y + 28, tx.cur.dst, COL_DIM)
    drawProgress(y + 60, tx.cur.size > 0 and tx.off / tx.cur.size or 1)
    lcd.drawText(20, y + 88, fmtSize(tx.off) .. " / " .. fmtSize(tx.cur.size), COL_DIM)
  end
  lcd.drawText(20, y + 120, string.format("Sent: %d   Skipped: %d   Failed: %d", tx.ok, tx.skip, tx.fail), COL_TEXT)
end

screens.recv = function()
  rxTick()
  if state ~= "recv" then return end
  drawHeader("Receiving")
  local y = LIST_Y + 10
  lcd.drawText(20, y, rx.status, COL_TEXT)
  if rx.f then
    lcd.drawText(20, y + 28, rx.path, COL_DIM)
    drawProgress(y + 60, rx.size > 0 and rx.got / rx.size or 1)
    lcd.drawText(20, y + 88, fmtSize(rx.got) .. " / " .. fmtSize(rx.size), COL_DIM)
  end
  lcd.drawText(20, y + 120, string.format("Received: %d   Skipped: %d   Failed: %d", rx.ok, rx.skip, rx.fail), COL_TEXT)
  lcd.drawText(20, LCD_H - 30, "Overwrite existing files: " .. (overwrite and "Yes" or "No"), COL_DIM)
end

screens.test = function(event, tap)
  local finished = test.n >= TEST_ROUNDS and not test.waiting
  if finished and (event == EVT_VIRTUAL_ENTER or tap == "again") then return startTest() end
  testTick()
  drawHeader("Connection test")
  local y = LIST_Y + 10
  local answers = string.format("Answers: %d of %d   Lost: %d", test.ok, test.ok + test.lost, test.lost)
  if not finished then
    lcd.drawText(20, y, string.format("Testing... %d / %d", test.n, TEST_ROUNDS), COL_TEXT)
    drawProgress(y + 36, test.n / TEST_ROUNDS)
    lcd.drawText(20, y + 66, answers, COL_DIM)
    return
  end

  if test.ok == 0 then
    lcd.drawText(20, y, "No answer", MIDSIZE + COL_ERR)
    lcd.drawText(20, y + 36, answers, COL_TEXT)
    lcd.drawText(20, y + 66, "- Model Share open on the other radio?", COL_DIM)
    lcd.drawText(20, y + 92, "- Serial port set to LUA on both radios?", COL_DIM)
    lcd.drawText(20, y + 118, "- Cable crossed: TX -> RX, RX -> TX, GND?", COL_DIM)
    lcd.drawText(20, y + 144, "- Same baud rate on both radios?", COL_DIM)
  else
    if test.ok == TEST_ROUNDS then
      lcd.drawText(20, y, "Connection OK", MIDSIZE + COL_OK)
    else
      lcd.drawText(20, y, "Unstable connection", MIDSIZE + COL_WARN)
    end
    lcd.drawText(20, y + 36, answers, COL_TEXT)
    lcd.drawText(20, y + 62, string.format("Response time: %d ms average, %d ms max",
      math.floor(test.rttSum / test.ok), test.rttMax), COL_TEXT)
    if peerRadio then
      local other = "Other radio: " .. peerRadio
      if peerProto ~= PROTO then other = other .. "  (different Model Share version!)" end
      lcd.drawText(20, y + 88, other, peerProto == PROTO and COL_DIM or COL_WARN)
    end
    if test.ok < TEST_ROUNDS then
      lcd.drawText(20, y + 114, "Check the cable and the plugs.", COL_DIM)
    end
  end
  drawButton("again", math.floor((LCD_W - 120) / 2), LCD_H - BAR_H - 10, 120, BAR_H, "Again")
end

screens.tsend = function(event, tap)
  if ts.phase == "check" and tap == "mixes" then addMixes() end
  if ts.phase == "nomix" and tap == "retry" then ts.phase = "check" end
  tsTick()
  if state ~= "tsend" then return end
  drawHeader("Sending")
  local y = LIST_Y + 10

  if ts.phase == "check" then
    lcd.drawText(20, y, "This model is not ready to send:", COL_WARN)
    local ly = y + 34
    if ts.rf then
      lcd.drawText(20, ly, "- Switch off Internal RF and External RF", COL_TEXT)
      lcd.drawText(20, ly + 26, "  in this model. Use a separate model for sharing.", COL_DIM)
      ly = ly + 60
    end
    if ts.missing > 0 then
      lcd.drawText(20, ly, "- Model Share mixes missing on " .. ts.missing .. " channels", COL_TEXT)
      lcd.drawText(20, ly + 26, "  They replace CH1 - CH8 of this model.", COL_DIM)
      if not ts.rf then
        drawButton("mixes", 20, LCD_H - BAR_H - 10, 200, BAR_H, "Add mixes")
      end
    end
    return
  end

  if ts.phase == "nomix" then
    lcd.drawText(20, y, "CH1 does not follow GV1", COL_ERR)
    lcd.drawText(20, y + 30, "Check the MShare mixes on CH1 - CH8", COL_DIM)
    lcd.drawText(20, y + 56, "and the outputs (limits) of this model.", COL_DIM)
    drawButton("retry", 20, LCD_H - BAR_H - 10, 160, BAR_H, "Retry")
    return
  end

  if ts.phase ~= "run" then
    lcd.drawText(20, y, "Preparing...", COL_TEXT)
    return
  end

  -- the speed can be changed while sending, the receiver follows by itself
  if tap == "speed" then
    tSpeed = tSpeed % #T_SPEEDS + 1
    ts.hold = T_SPEEDS[tSpeed].hold
  end
  drawButton("speed", LCD_W - 190, LCD_H - BAR_H - 40, 170, BAR_H, "Speed: " .. T_SPEEDS[tSpeed].name)

  local secs = (getTime() - ts.startTime) / 100
  if ts.pattern then
    lcd.drawText(20, y, "Sending test signal", COL_TEXT)
    lcd.drawText(20, y + 28, string.format("Symbol %d, step %d ms (set %d ms)", ts.syms,
      math.floor((ts.stepAvg or ts.hold) * 10), ts.hold * 10), COL_DIM)
    lcd.drawText(20, y + 54, "Start \"Receive test signal\" on the other radio.", COL_DIM)
    return
  end

  local q = ts.queue[ts.fi]
  lcd.drawText(20, y, string.format("Round %d   File %d of %d", ts.round, math.min(ts.fi, #ts.queue), #ts.queue), COL_TEXT)
  if q then lcd.drawText(20, y + 28, q.dst, COL_DIM) end
  if q and q.size > 0 then drawProgress(y + 60, (ts.ci or 0) * T_CHUNK / q.size) end
  -- the real step time can be longer than set when this radio runs the script less often
  local step = ts.stepAvg or ts.hold
  lcd.drawText(20, y + 90, string.format("Speed: %d bytes/s   Step: %d ms (set %d ms)",
    math.floor(500 / step), math.floor(step * 10), ts.hold * 10), COL_DIM)
  if ts.skipped > 0 then
    lcd.drawText(20, y + 116, ts.skipped .. " files skipped (over " .. fmtSize(T_MAX_FILE) .. ")", COL_WARN)
  end
  lcd.drawText(20, LCD_H - 30, "Sends in rounds until you stop.", COL_DIM)
end

screens.trecv = function()
  trTick()
  if state ~= "trecv" then return end
  drawHeader("Receiving")
  local y = LIST_Y + 10
  local now = getTime()

  if now - tr.sigTime > 100 then
    lcd.drawText(20, y, "No signal on the trainer input", COL_WARN)
    lcd.drawText(20, y + 28, "This radio: Trainer mode Master/Jack.", COL_DIM)
    lcd.drawText(20, y + 54, "Other radio: Model Share sending, Trainer mode Slave/Jack.", COL_DIM)
  elseif tr.pattern then
    local f = math.floor
    lcd.drawText(20, y, string.format("Symbols: %d   Missed: %d   Wrong: %d", tr.counted, tr.missed, tr.errSyms), COL_TEXT)
    lcd.drawText(20, y + 26, string.format("Script reads every %d ms (slowest %d ms)",
      tr.runs > 0 and f(tr.runSum * 10 / tr.runs) or 0, tr.runMax * 10), COL_DIM)
    lcd.drawText(20, y + 52, string.format("Worst value error: %d (must stay below %d)", f(tr.maxDev), f(T_STEP / 2)), COL_DIM)
    lcd.drawText(20, y + 78, string.format("Clock levels: %d / %d", f(tr.hi), f(tr.lo)), COL_DIM)
    local text, col
    if tr.counted < 30 then
      text, col = "Measuring...", COL_TEXT
    elseif tr.errSyms > tr.counted / 20 then
      text, col = "Values arrive too imprecise", COL_ERR
    elseif tr.missed > tr.counted / 20 then
      text, col = "Symbols are missed: try a slower speed", COL_WARN
    else
      text, col = "Link OK at this speed", COL_OK
    end
    lcd.drawText(20, y + 104, text, col)
  else
    local need, have, done = 0, 0, 0
    for _, f in pairs(tr.files) do
      if f.done then done = done + 1 end
      if f.need then
        need = need + f.need
        have = have + (f.done and f.need or math.min(f.count, f.need))
      end
    end
    local total = tr.nFiles and tostring(tr.nFiles) or "?"
    lcd.drawText(20, y, "Files complete: " .. done .. " of " .. total, COL_TEXT)
    drawProgress(y + 32, need > 0 and have / need or 0)
    local q = tr.good + tr.bad
    lcd.drawText(20, y + 62, string.format("Packets OK: %d   Bad: %d   Quality: %d%%",
      tr.good, tr.bad, q > 0 and math.floor(100 * tr.good / q) or 0), COL_DIM)
    -- real payload speed and the time still needed, counted from the first piece received
    local secs = tr.firstSym and (now - tr.firstSym) / 100 or 0
    if secs > 5 and have > 0 then
      local rate = have * T_CHUNK / secs
      local left = (need - have) * T_CHUNK / rate
      lcd.drawText(20, y + 92, string.format("Data: %d bytes/s   About %d:%02d min left",
        math.floor(rate), math.floor(left / 60), math.floor(left % 60)), COL_DIM)
    end
  end
  if not tr.pattern then
    lcd.drawText(20, y + 118, string.format("Received: %d   Skipped: %d   Failed: %d", tr.ok, tr.skip, tr.fail), COL_TEXT)
  end
  local r = tr.raw
  lcd.drawText(20, y + 146, string.format("TR1-8: %d %d %d %d %d %d %d %d",
    r[1] or 0, r[2] or 0, r[3] or 0, r[4] or 0, r[5] or 0, r[6] or 0, r[7] or 0, r[8] or 0), COL_DIM)
  lcd.drawText(20, LCD_H - 30, "Overwrite existing files: " .. (overwrite and "Yes" or "No"), COL_DIM)
end

screens.done = function(event, tap)
  if event == EVT_VIRTUAL_ENTER or tap == "ok" then return show("menu") end
  drawHeader(doneTitle)
  local y = LIST_Y + 10
  lcd.drawText(20, y, doneOk and "OK" or "Problem", MIDSIZE + (doneOk and COL_OK or COL_ERR))
  for i, line in ipairs(doneLines) do
    lcd.drawText(20, y + 20 + i * 28, line, COL_TEXT)
  end
  drawButton("ok", math.floor((LCD_W - 120) / 2), LCD_H - BAR_H - 10, 120, BAR_H, "OK")
end

---------------------------------------------------------------------------

local function back()
  if state == "menu" then return true end
  if state == "send" then
    if tx.f then io.close(tx.f); tx.f = nil end
  elseif state == "recv" then
    rxDropPartial()
  elseif state == "tsend" then
    tsStop()
  elseif state == "trecv" then
    trDropFin()
  elseif state == "browse" and cwd ~= "/" then
    openBrowser(parent(cwd) == "" and "/" or parent(cwd))
    return false
  end
  show("menu")
  return false
end

local function init()
  if getVersion then
    local _, radio = getVersion()
    myRadio = radio or "?"
  end
  checkPorts()
  detectTrainerRole()
end

local function run(event, touchState)
  if not serialWrite or not serialRead or not dir or not fstat then
    lcd.clear(COL_BG)
    lcd.drawText(10, 10, "Model Share needs EdgeTX with", COL_TEXT)
    lcd.drawText(10, 40, "serial and file system Lua functions.", COL_TEXT)
    return (event == EVT_VIRTUAL_EXIT) and 1 or 0
  end

  local tap
  if touchState then tap = touchInput(event, touchState) end
  if event == EVT_VIRTUAL_EXIT or (EVT_EXIT_BREAK and event == EVT_EXIT_BREAK) or tap == "back" then
    if back() then return 1 end
    event, tap = 0, nil
  end

  -- transfers handle the serial link themselves, all other screens answer pings and echoes
  if link == "serial" then
    if state ~= "send" and state ~= "recv" then idleTick() end
    if state ~= "send" then sendPing() end
  end

  regions = {}
  screens[state](event, tap)
  lastRegions = regions
  return 0
end

return { init = init, run = run }
