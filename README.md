# Magmatter 生産制御 (OpenComputers / GTNH)

GregTech New Horizons の **Heliofusion Exoticizer** で Molten Magmatter を自動生産する
OpenComputers (1.7.10) 用スクリプトです。

このバージョンは **GTNH 2.9.0**（OpenComputers 1.12.68-GTNH）向けです。2.8.4 以前の API とは互換性がありません。

## 仕組み

1. **Output Bus の dust を検知**（= 1 サイクル分の出力が揃った合図）
2. **2 つの Output Hatch の液体量**（Spatially Enlarged Fluid / Tachyon Rich Temporal Fluid）を読む
3. 必要 plasma 量を計算： `ceil(|液体A − 液体B| × 144)`（1 dust = 144 mB）
4. **dust のラベルから plasma 種類を判定**
5. Database の名前付き paper を出力、ネイティブ Fluid Stack を入力とする Input ME Interface の **fake pattern にエンコードして発注**
6. 発注成功時のみ：液体を **Input Hatch へ再循環**し、dust を **Trashcan へ廃棄**

> Gluon (Quark-Gluon Plasma) モードは非対応です。

## 必要なハードウェア

- Computer（GPU/CPU/RAM/HDD/EEPROM、OpenOS インストール済み）
- **Adapter + Database Upgrade (Tier 3)** … 1 セット
- **Input ME Interface**（fake pattern 発注用）… slot1 に **エンコード済み AE2 Processing Pattern** を 1 枚入れておく（液体を直接出力する構成では ME Dual Interface を使用）
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
| `fluidSources` | Output Hatch ×2。各 `{ transposerAddress, sourceSide, sourceTank, sinkSide }`。`sourceSide`=Hatch 向き / `sinkSide`=Input Hatch 向き。どちらが Spatial / Tachyon かは区別不要（順不同） |
| `dust` | `{ transposerAddress, busSide, trashSide, busSlot }`。`busSide`=Output Bus / `trashSide`=Trashcan |
| `pollInterval` | dust 検知のポーリング間隔（秒、既定 `0.5`）。プロセス共通 |
| `machines` | （任意）複数台構成用。台ごとの設定（上記 `inputMeInterfaceAddress`／`databaseAddress`／`fluidSources`／`dust` と同じ形）の配列。指定するとトップレベルの機器設定は無視される |

> アドレスは OpenComputers の **Analyzer** で機器を右クリックすると取得できます（先頭 8 文字程度の部分一致で可）。
> `side` は `bottom=0 top=1 north=2 south=3 west=4 east=5`。

### GTNH 2.8.4 からの移行

1. Computer で `components` を実行し、`me_interface` または `fluid_interface` の UUID を確認する。更新後に UUID が変わっている場合は `config.lua` の `inputMeInterfaceAddress` を更新する。Database と Transposer の UUID も確認する。
2. slot1 の旧液体テンプレートを、ME Processing Pattern Terminal で適当な入力・出力を設定してエンコードした **Processing Pattern**（通常の Crafting Pattern ではない）に交換する。起動時に内容は上書きされる。
3. 新しい `main.lua` を配置する。Database は fake recipe 用 paper の登録に引き続き必要だが、Fluid Drop の登録は不要。
4. 最初は1サイクルだけ実行し、パターンの入力が正しい種類・数量の液体になっていることと、plasma が意図した宛先に供給されることを確認する。

2.9 では [OpenComputers #169](https://github.com/GTNewHorizons/OpenComputers/pull/169) によりパターン API の引数順序が変更された。Database 経由の数量制限を回避するため、plasma は `fluid` 型のネイティブ Stack として指定する。

### 複数台を 1 プロセスで制御する

`config.machines` に台ごとの設定を並べると、**1 プロセスで複数台**を制御できます。各台は毎ティック
順番に 1 サイクルずつ処理されます（逐次マルチプレクス）。`machines` を指定した場合、トップレベルの
機器設定は無視され、`pollInterval` のみがプロセス共通として使われます。`machines` を書かなければ
従来どおり 1 台構成として動作します（挙動は変わりません）。

```lua
config = {
  pollInterval = 0.5,
  machines = {
    { name = "台1", inputMeInterfaceAddress = "...", databaseAddress = "...", fluidSources = { ... }, dust = { ... } },
    { name = "台2", inputMeInterfaceAddress = "...", databaseAddress = "...", fluidSources = { ... }, dust = { ... } },
  },
}
```

> **複数台では各台に専用の `inputMeInterfaceAddress` と専用の `databaseAddress` が必須です。**
> fake recipe 名は database アドレス（先頭 8 文字）から作られるため、共有すると他台の発注と混線します。
> Input ME Interface も fake pattern を slot1 に書き込むため共有できません。重複を検出した場合は
> 起動時にエラーで停止します。各台にはそれぞれ専用の **Adapter + Database Upgrade (Tier 3)** と
> **Input ME Interface** を用意してください（Transposer / Output Hatch / Output Bus / Trashcan も台ごとに必要）。

## 実行

`config.lua` と `main.lua` をコンピュータの同じディレクトリに配置し、以下で起動します。
設定は起動ごとに `main.lua` と同じディレクトリから読み込むため、編集後はスクリプトを再実行するだけで反映されます（Computer の再起動は不要）。

```shell
main
```

起動後は dust が Output Bus に出るたびに 1 サイクルを自動処理します。終了は `Ctrl+C`。

## 動作確認

1. `config.lua` を自環境に合わせて記入。Input ME Interface の slot1 にエンコード済み Processing Pattern を入れる。
2. `main` 実行 → 起動バナーと「待機中」表示を確認。
3. 機械を稼働させ、dust 出力時に
   (a) 液体が Input Hatch へ移動 /
   (b) dust が Trashcan へ消える /
   (c) 該当 plasma が AE で発注され機械へ供給 /
   (d) コンソールに `[<element>] plasma xN ...` が出る
   ことを確認。
4. AE 内の plasma を枯渇させ、発注失敗時に dust / 液体が保持され、補充後に自動再開することを確認。

## 注意

- Input ME Interface の入力側サブネットは、CPU すべてに **Crafting Monitor** を装備しておく必要があります。

## クレジット

本プロジェクトは [GTNH-OC-God-Forge-Control](https://github.com/Navatusein/GTNH-OC-God-Forge-Control) を参考に実装しています。設計やロジックの一部はこのプロジェクトに由来します。

- 原作者: Bohdan Kutsulima ([@Navatusein](https://github.com/Navatusein))
- ライセンス: [MIT License](https://github.com/Navatusein/GTNH-OC-God-Forge-Control/blob/main/LICENSE)

> Copyright (c) 2025 Bohdan Kutsulima
> Licensed under the MIT License.
