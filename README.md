# Magmatter 生産制御 (OpenComputers / GTNH)

GregTech New Horizons の **Heliofusion Exoticizer** で Molten Magmatter を自動生産する
OpenComputers (1.7.10) 用スクリプトです。

参考実装 [GTNH-OC-God-Forge-Control](https://github.com/Navatusein/GTNH-OC-God-Forge-Control)

## 仕組み

1. **Output Bus の dust を検知**（= 1 サイクル分の出力が揃った合図）
2. **2 つの Output Hatch の液体量**（Spatially Enlarged Fluid / Tachyon Rich Temporal Fluid）を読む
3. 必要 plasma 量を計算： `ceil(|液体A − 液体B| × plasmaCoefficient)`
4. **dust のラベルから plasma 種類を判定**
5. database + Input ME Interface の **fake pattern にエンコードして発注**
6. 発注成功時のみ：液体を **Input Hatch へ再循環**し、dust を **Trashcan へ廃棄**

> Gluon (Quark-Gluon Plasma) モードは非対応です。

## 必要なハードウェア

- Computer（GPU/CPU/RAM/HDD/EEPROM、OpenOS インストール済み）
- **Adapter + Database Upgrade (Tier 3)** … 1 セット
- **Input ME Interface**（fake pattern 発注用）… slot1 に **空の液体クラフトテンプレート（ピンク）** を 1 枚入れておく
- **Transposer**（機器ごとに 1 台）
  - 各 Output Hatch ×2 用
  - Output Bus 用（Trashcan と同一 Transposer の両側に隣接させる）
- **Trashcan**（dust 廃棄先）

### 配置上の重要要件

`transferFluid` / `transferItem` は **同一 Transposer 上の source ↔ sink 間でのみ** 動作します。

- 各 **Output Hatch 用 Transposer** は、その **Output Hatch** と **Input Hatch** の両方に隣接させてください
  （例：Input Hatch を中央に置き、左右の Transposer が両方とも触れる配置）。
- **Output Bus 用 Transposer** は、**Output Bus** と **Trashcan** の両方に隣接させてください。

## 設定 (`config.lua`)

| 項目 | 説明 |
|------|------|
| `inputMeInterfaceAddress` | fake pattern を発注する Input ME Interface のアドレス |
| `databaseAddress` | 通常は `nil`（`component.database` を自動使用）。複数ある場合のみ指定 |
| `fluidSources` | Output Hatch ×2。各 `{ name, transposerAddress, sourceSide, sourceTank, sinkSide }`。`sourceSide`=Hatch 向き / `sinkSide`=Input Hatch 向き。どちらが Spatial / Tachyon かは区別不要（順不同） |
| `dust` | `{ transposerAddress, busSide, trashSide, busSlot }`。`busSide`=Output Bus / `trashSide`=Trashcan |
| `plasmaCoefficient` | 必要 plasma 量の係数（既定 `144`）。**自機の要求量と合わない場合は要調整** |
| `pollInterval` | dust 検知のポーリング間隔（秒、既定 `0.5`） |
| `settleDelay` | dust 検知後、液体量を読むまでの安定待ち（秒、既定 `0.2`） |

> アドレスは OpenComputers の **Analyzer** で機器を右クリックすると取得できます（先頭 8 文字程度の部分一致で可）。
> `side` は `bottom=0 top=1 north=2 south=3 west=4 east=5`。

## 実行

`config.lua` と `main.lua` をコンピュータに配置し、以下で起動します。

```shell
main
```

起動後は dust が Output Bus に出るたびに 1 サイクルを自動処理します。終了は `Ctrl+C`。

## 動作確認

1. `config.lua` を自環境に合わせて記入。Input ME Interface の slot1 に空の液体テンプレートを入れる。
2. `main` 実行 → 起動バナーと「待機中」表示を確認。
3. 機械を稼働させ、dust 出力時に
   (a) 液体が Input Hatch へ移動 /
   (b) dust が Trashcan へ消える /
   (c) 該当 plasma が AE で発注され機械へ供給 /
   (d) コンソールに `[<element>] plasma xN ...` が出る
   ことを確認。
4. AE 内の plasma を枯渇させ、発注失敗時に dust / 液体が保持され、補充後に自動再開することを確認。

## 注意

- `plasmaCoefficient` は参考実装の `144`（1 dust = 144 fluid_drop）を踏襲しています。
  生産が過不足する場合はこの値を調整してください。
- Input ME Interface の入力側サブネットは、CPU すべてに **Crafting Monitor** を装備しておく必要があります（参考実装と同様）。
