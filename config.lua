-- =============================================================================
-- Magmatter 生産制御 設定ファイル
--
-- アドレスは OpenComputers の "Analyzer" で機器を右クリックすると取得できます
-- （先頭8文字程度の部分一致でOK）。
-- side は require("sides") の値： bottom=0 top=1 north=2 south=3 west=4 east=5
-- =============================================================================

local sides = require("sides")

local config = {
  -- ---------------------------------------------------------------------------
  -- Input ME Interface
  -- fake pattern をエンコードして plasma を発注する入力側の ME Interface。
  -- slot1 に「空の液体クラフトテンプレート（ピンク）」を1枚入れておくこと。
  -- ---------------------------------------------------------------------------
  inputMeInterfaceAddress = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",

  -- ---------------------------------------------------------------------------
  -- Database Upgrade (Adapter内・Tier3)
  -- 通常は nil のままで component.database が自動使用される。
  -- データベースが複数ある場合のみアドレスを指定する。
  -- ---------------------------------------------------------------------------
  databaseAddress = nil,

  -- ---------------------------------------------------------------------------
  -- Output Hatch ×2 （Spatially Enlarged Fluid / Tachyon Rich Temporal Fluid）
  --
  -- 各 Output Hatch には専用の Transposer を隣接させる。
  -- 必要 plasma 量は |amountA - amountB| から計算するため、どちらが Spatial /
  -- Tachyon かは区別不要（順不同でよい）。name は表示用のラベル。
  --
  -- 【重要・配置要件】
  --   transferFluid は「同一 Transposer 上の source ↔ sink 間」でしか行えない。
  --   そのため各 Output Hatch 用 Transposer は、その Output Hatch (sourceSide) と
  --   Input Hatch (sinkSide) の両方に隣接させること。
  --   （例：Input Hatch を中央に置き、左右の Transposer が両方とも触れる配置）
  -- ---------------------------------------------------------------------------
  fluidSources = {
    {
      name = "Fluid A",
      transposerAddress = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
      sourceSide = sides.north, -- Output Hatch 向き（読み取り元）
      sourceTank = 1,           -- 通常 1
      sinkSide   = sides.south, -- Input Hatch 向き（再循環先）
    },
    {
      name = "Fluid B",
      transposerAddress = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
      sourceSide = sides.north,
      sourceTank = 1,
      sinkSide   = sides.south,
    },
  },

  -- ---------------------------------------------------------------------------
  -- Output Bus (dust) → Trashcan
  -- dust の種類で必要 plasma を判定し、判定後に Trashcan へ廃棄する。
  -- busSide と trashSide は同一 Transposer の両側に来るように配置する。
  -- ---------------------------------------------------------------------------
  dust = {
    transposerAddress = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
    busSide   = sides.north, -- Output Bus 向き
    trashSide = sides.south, -- Trashcan 向き
    busSlot   = 1,           -- dust を読むスロット（通常 1）
  },

  -- ---------------------------------------------------------------------------
  -- 必要 plasma 量の係数： amount = ceil(|amountA - amountB| * plasmaCoefficient)
  -- 参考実装の "* 144"（1 dust = 144 fluid_drop）を踏襲。
  -- 自機の要求量と合わない場合はここを調整すること。
  -- ---------------------------------------------------------------------------
  plasmaCoefficient = 144,

  -- ---------------------------------------------------------------------------
  -- タイミング
  -- ---------------------------------------------------------------------------
  pollInterval = 0.5, -- dust 検知のポーリング間隔（秒）
  settleDelay  = 0.2, -- dust 検知後、液体量を読むまでの安定待ち（秒）
}

return config
