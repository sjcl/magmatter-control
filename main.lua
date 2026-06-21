-- =============================================================================
-- Magmatter 生産制御 (OpenComputers 1.7.10 / GTNH Heliofusion Exoticizer)
--
-- 仕組み（1サイクル）:
--   1. Output Bus の dust を検知（= 1 サイクル分の出力が揃った合図）
--   2. 2つの Output Hatch から液体量を読み取り、必要 plasma 量を計算
--   3. dust のラベルから plasma 種類を判定
--   4. database + Input ME Interface の fake pattern にエンコードして発注
--   5. 発注成功時のみ：液体を Input Hatch へ再循環し、dust を Trashcan へ廃棄
--
-- =============================================================================

local component = require("component")
local computer = require("computer")
local config = require("config")

-- -----------------------------------------------------------------------------
-- Magmatter 用 plasma テーブル （dust ラベル → plasma fluid id）
-- 参考実装の Magmatter リストのうち、dust として出力され得る 15 種のみ。
-- （Spatially Enlarged Fluid / Tachyon Rich Temporal Fluid は再循環対象なので除外）
-- -----------------------------------------------------------------------------
local plasmaList = {
  ["Awakened Draconium"] = "plasma.draconiumawakened",
  ["Bedrockium"]         = "plasma.bedrockium",
  ["Celestial Tungsten"] = "plasma.celestialtungsten",
  ["Chromatic Glass"]    = "plasma.chromaticglass",
  ["Cosmic Neutronium"]  = "plasma.cosmicneutronium",
  ["Draconium"]          = "plasma.draconium",
  ["Dragonblood"]        = "plasma.dragonblood",
  ["Flerovium"]          = "plasma.flerovium_gt5u",
  ["Hypogen"]            = "plasma.hypogen",
  ["Ichorium"]           = "plasma.ichorium",
  ["Infinity"]           = "plasma.infinity",
  ["Neutronium"]         = "plasma.neutronium",
  ["Rhugnor"]            = "plasma.rhugnor",
  ["Six-Phased Copper"]  = "plasma.sixphasedcopper",
  ["Tritanium"]          = "plasma.tritanium",
}

-- -----------------------------------------------------------------------------
-- コンポーネント解決
-- -----------------------------------------------------------------------------
local function discoverProxy(address, name, ctype)
  local full = component.get(address, ctype)
  if full == nil then
    error("不正なアドレス ("..ctype..") : "..name)
  end
  return component.proxy(full, ctype)
end

local meInterface = discoverProxy(config.inputMeInterfaceAddress, "Input ME Interface", "me_interface")

local database = config.databaseAddress
  and discoverProxy(config.databaseAddress, "Database", "database")
  or component.database

if database == nil then
  error("Database が見つかりません（Adapter に Database Upgrade(Tier3) を入れてください）")
end

-- Transposer プロキシは address でキャッシュ
local transposerCache = {}
local function getTransposer(address)
  if transposerCache[address] == nil then
    transposerCache[address] = discoverProxy(address, "Transposer", "transposer")
  end
  return transposerCache[address]
end

local fakeRecipeName = "Fake recipe "..database.address:sub(1, 8)
local plasmaIndex = {} -- label → database slot index

-- -----------------------------------------------------------------------------
-- database / fake pattern
-- -----------------------------------------------------------------------------

---database に paper(=fake recipe) と各 plasma を登録
local function fillDatabase()
  database.set(1, "minecraft:paper", 0, "{display:{Name:\""..fakeRecipeName.."\"}}")

  local index = 2
  for label, fluid in pairs(plasmaList) do
    local ok = database.set(index, "ae2fc:fluid_drop", 0, "{Fluid:\""..fluid.."\"}")
    if ok == false then
      error("database への登録に失敗: "..label)
    end
    plasmaIndex[label] = index
    index = index + 1
  end
end

---パターン1の入出力を初期化（output=paper / input=paper）
local function clearPattern()
  local pattern = meInterface.getInterfacePattern(1)
  if pattern == nil then
    error("Input ME Interface の slot1 にパターンがありません（空の液体テンプレートを入れてください）")
  end

  for key in pairs(pattern.outputs) do
    meInterface.clearInterfacePatternOutput(1, key)
  end
  for key in pairs(pattern.inputs) do
    meInterface.clearInterfacePatternInput(1, key)
  end

  meInterface.setInterfacePatternOutput(1, database.address, 1, 1, 1)
  meInterface.setInterfacePatternInput(1, database.address, 1, 1, 1)
end

---必要な plasma を input slot1 にエンコード（1サイクル1種なので1スロットのみ）
---@param label string
---@param amount number
---@return boolean
local function encodePattern(label, amount)
  local index = plasmaIndex[label]
  if index == nil then
    return false
  end
  meInterface.setInterfacePatternInput(1, database.address, index, amount, 1)
  return true
end

-- -----------------------------------------------------------------------------
-- crafting CPU / 発注
-- -----------------------------------------------------------------------------

local function hasFreeCpu()
  for _, value in pairs(meInterface.getCpus()) do
    if value.cpu.isBusy() == false then
      return true
    end
  end
  return false
end

---空き CPU を最大30秒待つ（無ければそのまま進む）
local function waitFreeCpu()
  local deadline = computer.uptime() + 30
  while not hasFreeCpu() do
    if computer.uptime() > deadline then
      return
    end
    os.sleep(0.5)
  end
end

---fake recipe を1個発注（プランニング完了まで待つ）
---@return boolean success
local function requestCraft()
  local recipe = meInterface.getCraftables({label = fakeRecipeName})[1]
  if recipe == nil then
    return false
  end

  local craft = recipe.request(1)
  while craft.isComputing() == true do
    os.sleep(0.05)
  end

  return craft.hasFailed() == false
end

---前回の残骸（実行中の fake recipe craft）をキャンセル
local function cancelFakeCraft()
  for _, value in pairs(meInterface.getCpus()) do
    if value.cpu.isBusy() == true then
      local output = value.cpu.finalOutput()
      if output ~= nil and output.label == fakeRecipeName then
        value.cpu.cancel()
      end
    end
  end
end

-- -----------------------------------------------------------------------------
-- Transposer 直接操作（dust / 液体）
-- -----------------------------------------------------------------------------

---Output Bus の dust を読み、plasma 種別名と元ラベルを返す
---@return string|nil element
---@return string|nil fullLabel
local function readDust()
  local transposer = getTransposer(config.dust.transposerAddress)
  local stack = transposer.getStackInSlot(config.dust.busSide, config.dust.busSlot or 1)
  if stack == nil then
    return nil
  end

  local label = stack.label or stack.name or ""
  local element = label:match("Pile of%s(.+)%sDust") or label:match("(.+) Dust") or label
  return element, label
end

---dust を Trashcan へ廃棄
local function trashDust()
  local transposer = getTransposer(config.dust.transposerAddress)
  transposer.transferItem(config.dust.busSide, config.dust.trashSide, 64, config.dust.busSlot or 1)
end

---2つの Output Hatch の液体量を読む
---@return number[] amounts
local function readFluidAmounts()
  local amounts = {}
  for i, source in ipairs(config.fluidSources) do
    local transposer = getTransposer(source.transposerAddress)
    local fluid = transposer.getFluidInTank(source.sourceSide, source.sourceTank or 1)
    amounts[i] = (fluid and fluid.amount) or 0
  end
  return amounts
end

---液体を Input Hatch へ再循環
---@param amounts number[]
local function recycleFluids(amounts)
  for i, source in ipairs(config.fluidSources) do
    if amounts[i] and amounts[i] > 0 then
      local transposer = getTransposer(source.transposerAddress)
      transposer.transferFluid(source.sourceSide, source.sinkSide, amounts[i])
    end
  end
end

-- -----------------------------------------------------------------------------
-- メインサイクル
-- -----------------------------------------------------------------------------

---1サイクル処理
---@return boolean processed true=処理した / false=dust無し or 失敗（次ループで再試行）
local function runCycle()
  -- 1) dust 検知（トリガ）
  local element, fullLabel = readDust()
  if element == nil then
    return false
  end

  -- 2) plasma 種類判定
  if plasmaList[element] == nil then
    io.stderr:write("不明な dust: "..tostring(fullLabel).."（廃棄せず保持）\n")
    return false
  end

  -- 3) 液体量読み取り & 必要 plasma 量計算
  local amounts = readFluidAmounts()
  local amount = math.ceil(math.abs((amounts[1] or 0) - (amounts[2] or 0)) * config.plasmaCoefficient)

  -- 必要量ゼロ：発注せず再循環＆廃棄のみ
  if amount <= 0 then
    recycleFluids(amounts)
    trashDust()
    print(string.format("[%s] plasma 不要 (A=%d B=%d) 再循環のみ", element, amounts[1] or 0, amounts[2] or 0))
    return true
  end

  -- 4) fake pattern エンコード
  if not encodePattern(element, amount) then
    io.stderr:write("plasma をエンコードできません: "..element.."\n")
    return false
  end

  -- 5) 発注
  waitFreeCpu()
  if not requestCraft() then
    io.stderr:write(string.format("craft 発注失敗: %s x%d（保持して再試行）\n", element, amount))
    return false -- 再循環・廃棄せず、次ループで同じ dust/液体を読んで再試行
  end

  -- 6) 成功時のみ 再循環 & 廃棄
  recycleFluids(amounts)
  trashDust()
  print(string.format("[%s] plasma x%d 発注 (A=%d B=%d)", element, amount, amounts[1] or 0, amounts[2] or 0))
  return true
end

-- -----------------------------------------------------------------------------
-- 起動 & ループ
-- -----------------------------------------------------------------------------

print("==============================================")
print(" Magmatter 生産制御 起動")
print("  fake recipe : "..fakeRecipeName)
print("==============================================")

fillDatabase()
clearPattern()
cancelFakeCraft()

print("待機中（dust 検知でサイクル実行）... 終了は Ctrl+C")

while true do
  local ok, result = pcall(runCycle)
  if not ok then
    io.stderr:write("サイクルエラー: "..tostring(result).."\n")
    os.sleep(1)
  elseif result ~= true then
    os.sleep(config.pollInterval)
  end
end
