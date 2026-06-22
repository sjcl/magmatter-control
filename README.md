# Magmatter 生産制御 — config.lua ジェネレータ（GitHub Pages）

このブランチ（`gh-pages`）は [magmatter-control](https://github.com/sjcl/magmatter-control) の
`config.lua` をブラウザで生成する静的サイトです。フォームに入力すると `config.lua` が生成され、
**クリップボードにコピー**してゲーム内エディタへ直接貼り付けられます（ファイル保存は不要）。複数台構成にも対応。

## 公開URL

https://sjcl.github.io/magmatter-control/

## 構成

- `index.html` … ジェネレータ本体（依存なし・ビルド不要の単一ファイル）
- `.nojekyll` … GitHub Pages の Jekyll 処理を無効化

## GitHub Pages の有効化（初回のみ）

リポジトリの **Settings → Pages → Build and deployment** で

- **Source:** Deploy from a branch
- **Branch:** `gh-pages` / `(root)`

を選択して保存すると上記URLで公開されます。

## ローカルで開く

`index.html` をブラウザで直接開くだけで動作します（サーバー不要）。

---

> ジェネレータが出力する `config.lua` の形式・各項目の意味は、`main` ブランチの
> [README](https://github.com/sjcl/magmatter-control/blob/main/README.md) を参照してください。
