-- =============================================================================
-- Magmatter 生産制御 (OpenComputers / GTNH 2.9 Heliofusion Exoticizer)
--
-- 仕組み（1サイクル）:
--   1. Output Bus の dust を検知（= 1 サイクル分の出力が揃った合図）
--   2. 2つの Output Hatch から液体量を読み取り、必要 plasma 量を計算
--   3. dust のラベルから plasma 種類を判定
--   4. database + Input ME Interface の fake pattern にエンコードして発注
--   5. 発注成功時のみ：液体を Input Hatch へ再循環し、dust を Trashcan へ廃棄
--
-- 複数台対応:
--   config.machines に台ごとの設定を並べると、1プロセスで全台を逐次制御する。
--   machines が無い場合は従来通りトップレベル config を1台として扱う（後方互換）。
--   ※ 複数台では各台に専用の Input ME Interface と専用 database が必須
--     （fake recipe 名が database アドレス由来のため、共有すると衝突する）。
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
-- 必要 plasma 量の係数： amount = ceil(|amountA - amountB| * PLASMA_PER_DUST)
-- 1 dust = 144 mB。この値はどの環境でも固定。
-- -----------------------------------------------------------------------------
local PLASMA_PER_DUST = 144

-- -----------------------------------------------------------------------------
-- コンポーネント解決
-- -----------------------------------------------------------------------------
local function discoverProxy(address, name, ctype)
  local full = component.get(address, ctype)
  if full == nil then
    error("Invalid address ("..ctype..") : "..name)
  end
  return component.proxy(full, ctype)
end

-- -----------------------------------------------------------------------------
-- 1台分の制御インスタンス
-- 台ごとに専用のコンポーネント proxy と状態を保持する。
-- mc = 1台分の config テーブル（inputMeInterfaceAddress / databaseAddress /
--       fluidSources / dust / name）。
-- -----------------------------------------------------------------------------
local function makeMachine(mc)
  -- 2.9: ME Dual Interface は fluid_interface として公開される。
  local address = component.get(mc.inputMeInterfaceAddress, "me_interface")
    or component.get(mc.inputMeInterfaceAddress, "fluid_interface")
  if not address then
    error("Invalid address (me_interface/fluid_interface): Input ME Interface "..tostring(mc.inputMeInterfaceAddress))
  end
  local meInterface = component.proxy(address)
  if not meInterface.setInterfacePatternInput or not meInterface.getInterfacePattern then
    error("Input ME Interface does not expose pattern methods: "..address)
  end

  local database = mc.databaseAddress
    and discoverProxy(mc.databaseAddress, "Database", "database")
    or component.database

  if database == nil then
    error("Database not found (install a Database Upgrade (Tier 3) in the Adapter)")
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

  -- ---------------------------------------------------------------------------
  -- database / fake pattern
  -- ---------------------------------------------------------------------------

  ---database に paper (=fake recipe) を登録
  local function fillDatabase()
    database.set(1, "minecraft:paper", 0, "{display:{Name:\""..fakeRecipeName.."\"}}")
  end

  ---パターン1の入出力を初期化（output=paper / input=paper）
  local function clearPattern()
    local pattern = meInterface.getInterfacePattern(1)
    if pattern == nil then
      error("No pattern in slot 1 of the Input ME Interface (insert an encoded Processing Pattern)")
    end
    if pattern.name ~= "appliedenergistics2:item.ItemEncodedUltimatePattern" then
      error("Slot 1 must contain an AE2 Processing Pattern (not a crafting or legacy fluid pattern)")
    end

    -- 2.9: index は第2引数。先頭を上書きしてから余分な要素を末尾から削除する。
    -- 途中で入力/出力が空になって Processing Pattern が無効になることを避ける。
    assert(meInterface.setInterfacePatternOutput(1, 1, database.address, 1, 1))
    assert(meInterface.setInterfacePatternInput(1, 1, database.address, 1, 1))

    local function clearExtra(stacks, clear)
      local indices = {}
      for key in pairs(stacks) do
        if type(key) == "number" and key > 1 then
          indices[#indices + 1] = key
        end
      end
      table.sort(indices, function(a, b) return a > b end)
      for _, index in ipairs(indices) do
        assert(clear(1, index))
      end
    end
    clearExtra(pattern.outputs, meInterface.clearInterfacePatternOutput)
    clearExtra(pattern.inputs, meInterface.clearInterfacePatternInput)
  end

  ---必要な plasma をネイティブ Fluid Stack として input slot1 にエンコード
  ---@param label string
  ---@param amount number mB
  ---@return boolean
  local function encodePattern(label, amount)
    local fluid = plasmaList[label]
    if fluid == nil then
      return false
    end
    -- Database 経由ではアイテムの最大スタック数に制限される。
    -- amount は FluidStack の生成用、size が AE Stack の実際の数量。
    return meInterface.setInterfacePatternInput(1, 1, {
      name = fluid,
      amount = 1,
      size = amount,
    }, "fluid") == true
  end

  -- ---------------------------------------------------------------------------
  -- crafting CPU / 発注
  -- ---------------------------------------------------------------------------

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

    return true
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

  -- ---------------------------------------------------------------------------
  -- Transposer 直接操作（dust / 液体）
  -- ---------------------------------------------------------------------------

  ---Output Bus の dust を読み、plasma 種別名と元ラベルを返す
  ---@return string|nil element
  ---@return string|nil fullLabel
  local function readDust()
    local transposer = getTransposer(mc.dust.transposerAddress)
    local stack = transposer.getStackInSlot(mc.dust.busSide, mc.dust.busSlot or 1)
    if stack == nil then
      return nil
    end

    local label = stack.label or stack.name or ""
    local element = label:match("Pile of%s(.+)%sDust") or label:match("(.+) Dust") or label
    return element, label
  end

  ---dust を Trashcan へ廃棄
  local function trashDust()
    local transposer = getTransposer(mc.dust.transposerAddress)
    transposer.transferItem(mc.dust.busSide, mc.dust.trashSide, 64, mc.dust.busSlot or 1)
  end

  ---2つの Output Hatch の液体量を読む
  ---@return number[] amounts
  local function readFluidAmounts()
    local amounts = {}
    for i, source in ipairs(mc.fluidSources) do
      local transposer = getTransposer(source.transposerAddress)
      local fluid = transposer.getFluidInTank(source.sourceSide, source.sourceTank or 1)
      amounts[i] = (fluid and fluid.amount) or 0
    end
    return amounts
  end

  ---液体を Input Hatch へ再循環
  ---@param amounts number[]
  local function recycleFluids(amounts)
    for i, source in ipairs(mc.fluidSources) do
      if amounts[i] and amounts[i] > 0 then
        local transposer = getTransposer(source.transposerAddress)
        transposer.transferFluid(source.sourceSide, source.sinkSide, amounts[i])
      end
    end
  end

  -- ---------------------------------------------------------------------------
  -- メインサイクル
  -- ---------------------------------------------------------------------------

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
      io.stderr:write("Unknown dust: "..tostring(fullLabel).." (kept, not discarded)\n")
      return false
    end

    -- 3) 液体量読み取り & 必要 plasma 量計算
    local amounts = readFluidAmounts()
    local amount = math.ceil(math.abs((amounts[1] or 0) - (amounts[2] or 0)) * PLASMA_PER_DUST)

    -- 必要量ゼロ：発注せず再循環＆廃棄のみ
    if amount <= 0 then
      recycleFluids(amounts)
      trashDust()
      print(string.format("[%s] no plasma needed (A=%d B=%d) recycle only", element, amounts[1] or 0, amounts[2] or 0))
      return true
    end

    -- 4) fake pattern エンコード
    if not encodePattern(element, amount) then
      io.stderr:write("Cannot encode plasma: "..element.."\n")
      return false
    end

    -- 5) 発注
    waitFreeCpu()
    if not requestCraft() then
      io.stderr:write(string.format("Craft request failed: %s x%d (kept, will retry)\n", element, amount))
      return false -- 再循環・廃棄せず、次ループで同じ dust/液体を読んで再試行
    end

    -- 6) 成功時のみ 再循環 & 廃棄
    recycleFluids(amounts)
    trashDust()
    print(string.format("[%s] plasma x%d requested (A=%d B=%d)", element, amount, amounts[1] or 0, amounts[2] or 0))
    return true
  end

  return {
    name           = mc.name,
    fakeRecipeName = fakeRecipeName,
    setup = function()
      fillDatabase()
      clearPattern()
      cancelFakeCraft()
    end,
    runCycle = runCycle,
  }
end

-- -----------------------------------------------------------------------------
-- config 正規化（後方互換）
--   config.machines があればそれを台リストに、無ければトップレベル config を
--   1台として包む。pollInterval はプロセス共通。
-- -----------------------------------------------------------------------------
local pollInterval = config.pollInterval or 0.5
local machineConfigs = config.machines or { config }

-- N>=2 では各台に専用 databaseAddress が必須
-- （component.database 既定だと fakeRecipeName が共有され、他台の craft と混線する）
if #machineConfigs > 1 then
  for i, mc in ipairs(machineConfigs) do
    if mc.databaseAddress == nil then
      error(string.format("databaseAddress is required in a multi-machine setup (machine #%d %s)", i, mc.name or ""))
    end
  end
end

-- -----------------------------------------------------------------------------
-- 起動 & ループ
-- -----------------------------------------------------------------------------

local machines = {}
for i, mc in ipairs(machineConfigs) do
  machines[i] = makeMachine(mc)
end

-- fake recipe 名 / Input ME Interface の重複検出（混線・誤キャンセルを防ぐ）
do
  local seenRecipe, seenIface = {}, {}
  for i, m in ipairs(machines) do
    local mc = machineConfigs[i]
    if seenRecipe[m.fakeRecipeName] then
      error("Duplicate fake recipe name (assign a separate database to each machine): "..m.fakeRecipeName)
    end
    if seenIface[mc.inputMeInterfaceAddress] then
      error("Duplicate inputMeInterfaceAddress (assign a separate Input ME Interface to each machine): "..tostring(mc.inputMeInterfaceAddress))
    end
    seenRecipe[m.fakeRecipeName] = true
    seenIface[mc.inputMeInterfaceAddress] = true
  end
end

print("==============================================")
print(" Magmatter production control - starting")
for i, m in ipairs(machines) do
  print(string.format("  [%s] fake recipe : %s", m.name or ("#"..i), m.fakeRecipeName))
end
print("==============================================")

for _, m in ipairs(machines) do
  m.setup()
end

print("Waiting (cycle runs on dust detection)... Ctrl+C to exit")

while true do
  local processedAny = false
  local erroredAny = false

  for _, m in ipairs(machines) do
    local ok, result = pcall(m.runCycle)
    if not ok then
      io.stderr:write("Cycle error: "..tostring(result).."\n")
      erroredAny = true
    elseif result == true then
      processedAny = true
    end
  end

  if processedAny then
    -- 何か処理した：間を置かず次ループ（残りの dust を続けて捌く）
  elseif erroredAny then
    os.sleep(1)
  else
    os.sleep(pollInterval)
  end
end
