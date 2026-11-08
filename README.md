# ClaudeCodeStatusLine.jl

Julia で書いた [Claude Code](https://claude.com/claude-code) のステータスライン。
モデル名、ディレクトリ、コンテキスト使用量 (トークン数・%)、出力トークン、コスト、経過時間、追加/削除行数を 1 行で表示します。

```
🤖 Opus 5.5 │ 📁 ClaudeCodeStatusLine.jl │ 🧠 ██░░░░░░░░ 40.1k/200.0k (20%) │ ✍️ 5.5k out │ 💰 $1.23 │ ⏱ 12m34s │ +120 -8
```

## インストール

Julia 1.12 以降が必要です。

### Pkg Apps (ローカルの開発版)

リポジトリのルートで次を実行します。

```julia
using Pkg
Pkg.Apps.develop(path=".")
```

`~/.julia/bin/statusline` にコマンドが作られます。
`~/.julia/bin` が `PATH` に入っていない場合は警告が出ますが、フルパスで呼べば動きます。

- シムはこのディレクトリを直接参照します。ソースを直せばそのまま反映されますが、ディレクトリを移動すると動かなくなります。
- 削除する場合:

  ```julia
  using Pkg
  Pkg.Apps.rm("ClaudeCodeStatusLine")
  ```

## Claude Code への設定

`~/.claude/settings.json` に追加します。

```json
{
  "statusLine": {
    "type": "command",
    "command": "~/.julia/bin/statusline"
  }
}
```

## 動作確認

Claude Code が stdin に渡す JSON を、手元で与えて確認できます。

```sh
echo '{"model":{"display_name":"Opus 5.5"},"workspace":{"current_dir":"/tmp/proj"}}' | ~/.julia/bin/statusline
```
# ClaudeCodeStatusLine.jl
