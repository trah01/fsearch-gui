# FSearch

Whole-disk file search for macOS: names in about 0.1 ms, typo-tolerant,
plus indexed search inside files. A CLI with a small daemon, a Rust crate,
or an MCP server for coding agents.

## macOS 图形界面

需要 macOS 13 或更新版本、Rust 和 Xcode Command Line Tools。在项目目录运行：

```sh
bash scripts/build-app.sh
open build/FSearch.app
```

窗口支持限定文件夹范围、即时搜索及格式分类。位置栏可直接输入或粘贴文件夹路径（支持 `~`），也可点击“选择…”选择文件夹；清空后搜索所有位置。
选择“自定义后缀”后输入 `pdf, docx, xlsx`，可同时筛选多个后缀，也支持 `.pdf` 写法。
“可执行文件”按常见后缀筛选应用和脚本（如 app、exe、sh、command），不按 Unix 执行权限筛选无后缀文件。

双击文件打开，右键可在访达中显示或复制路径。
文件名搜索一次加载全部匹配项，底部显示总数；未输入搜索词时按索引顺序浏览全部已索引文件。切换分类复用当前搜索数据；“更多操作 → 刷新结果”重新读取索引中的最新记录。列表使用原生表格按可见行绘制，仅对可见行计算显示文字，排序和目录优先对全部结果生效。选中文件后按空格快速查看，`⌘F` 聚焦搜索框，`⌘O` 选择文件夹，`⌘,` 打开设置。
首次使用需要建立索引，若提示索引尚未就绪，稍后点击“重试”。
界面与命令行共用索引。“设置”（`⌘,`）可检查完全磁盘访问权限以及各磁盘的读取和索引状态。
内置硬盘的受保护文件夹需要在系统设置的“隐私与安全性 → 完全磁盘访问权限”中添加并启用 FSearch，然后点击“重新载入权限”。“内置硬盘”旁的“重建索引”重新扫描内置存储，保留其他磁盘的索引。
每块外置磁盘通过各自的“申请权限”选择并授权根目录，再点击该磁盘旁的“重建索引”。索引按磁盘单独保存，重建完成后参与搜索，后续通过该按钮更新。磁盘断开时不返回其结果，重新连接原磁盘后恢复使用已保存的索引。
搜索控件位于标题栏下方，使用不透明背景。关闭搜索窗口后，点击 Dock 图标可重新打开。

```
cargo build --release && ./target/release/fsearch install   # -> ~/.local/bin/fsearch
fsearch fsearch main              # find files by name
fsearch 'ext:rs grep:apply_dir'   # search inside files
```

Or skip the Rust toolchain with a release build for Apple Silicon:

```
curl -L https://github.com/noahdunnagan/fsearch/releases/latest/download/fsearch-aarch64-apple-darwin.tar.gz | tar xz && ./fsearch install
```

## Speed

M4 Mac mini, a home holding the Linux or the Chromium source tree, vs the
previous version (b88f4e9). Medians; Linux / Chromium.

| | before | now |
|---|---:|---:|
| right file first, name search | 83% / 86% | 93% / 97% |
| right file first, two typos | 11% / 15% | 74% / 93% |
| find a file by name | 0.045 / 0.10 ms | 0.054 / 0.12 ms |
| an edited file greppable | 2.1 s | 1.3 ms |
| a rename or delete visible | 45 / 47 ms | 18 / 15 ms |
| first run, a name in a folder | 7.8 / 7.8 s | 0.18 / 1.2 s |
| first run, every match in the tree | 10.9 / 12.2 s | 2.4 / 10.8 s |
| files grep can search (rg's own set) | 96% / 92% | 99.9% / 99.8% |
| grep, first page | 0.29 / 0.48 ms | 0.33 / 0.65 ms |
| index on disk | 503 / 893 MB | 309 / 600 MB |
| peak memory while indexing | 1.13 / 1.37 GB | 0.77 / 0.94 GB |
| daemon memory | 19 / 100 MB | 21 / 35 MB |

The index is a third smaller while holding a third more text: one 3-bit
filter per file instead of two, compressed posting lists and paths, and
bit-packed name arrays read in place. Grep's first page reads a few more
files for it, and the deeper typo search costs a little on names.

## Queries

```
fsearch 'readme in:~/Developer'          # inside a folder
fsearch 'type:image size:>5mb mtime:<7d'
fsearch 'ext:rs regex:fn\s+\w+_dir'      # regex inside files
fsearch 'sym:apply_dir'                  # where it's defined
fsearch 'src/**/*.{c,h} !test/ init'     # globs, in or out
fsearch 'git:modified in:~/Developer/app'
```

Words are fuzzy and forgive a typo at any letter, two in words of 8+
(`mian.rs` finds `main.rs`); several words can spell one name. Accented
names match however they were stored. Also `'exact`, `^prefix`, `suffix$`
and `!exclude`. Filters: `ext:` `type:` `kind:` `in:` `size:` `mtime:`
`re:` `path:` `grep:` `regex:` `sym:` `limit:` and `git:` (`modified`
`staged` `untracked` `clean` `tracked` `ignored` `conflict`). Content search is
smart-case, and regexes match within a line, as in ripgrep.

## What grep covers

Text files up to 1 MB, and up to 10 MB inside git repos, minus what git
ignores. It leaves out lockfiles, JSON of 100 KB and up, minified or
bundled assets, linked git worktrees (their main checkout is indexed), and
build-output folders outside repos. To leave out more, list folders in
`~/Library/Application Support/FSearch/content-skip.txt`, one per line
(`~` and `#` comments work). Names are always indexed, and a grep inside
a file you name still reads it.

## Full Disk Access

From a terminal with Full Disk Access it indexes everything. As a login
item (`fsearch install --login`), grant `~/.local/bin/fsearch` access in
System Settings > Privacy & Security, again after each rebuild. Without
access it skips protected folders instead of prompting.

## API

JSON lines over `~/Library/Application Support/FSearch/fsearch.sock`, or
`fsearch stdio`:

```json
{"q": "fsearch main", "limit": 20, "offset": 20}
{"op": "grep", "pattern": "apply_dir", "in": "~/Developer", "context": 2}
{"q": "main.rs", "boost": true, "near": "~/Developer/app/src/lib.rs", "git": true}
{"op": "open", "path": "~/Developer/app/src/main.rs"}
{"op": "recent", "in": "~/Developer/app"}
```

`open` tells it what you opened; `"boost": true` ranks those higher for a
while, `near` favors files close to the one you're in, and `recent` lists
what you worked on lately. `"git": true` adds each hit's git status.

For coding agents, `fsearch mcp` is an MCP server on stdio with
`find_files`, `grep` and `multi_grep`.

Or link the crate:

```rust
let engine = fsearch::Engine::start(fsearch::Options { dir: fsearch::default_dir(&home), home: home.clone(), skip: None })?;
let hits = engine.search(&fsearch::Query::parse("fsearch main", &home)?)?;
```

An app and the CLI share one index: the first process owns it, the rest
follow.

## How it works

- Crawls the disk once with `getattrlistbulk`, then follows FSEvents:
  changes show up in about 15 ms, and a restart replays only what changed.
  On a first run, a search in a folder indexes that folder first.
- Names live in one mmap'd file, folder by folder, so `in:` is a range. A
  bitmap of each name's letters rules out most names before scoring.
- Content search is a trigram index plus a per-file filter, so a search
  only reads files likely to match. Identical files are indexed once, and
  deleted files' entries are compacted away. Matches are read fresh from
  disk; files edited since the last index sync are read directly.
- The daemon runs with malloc's space-efficient mode, so it gives memory
  back when idle.
