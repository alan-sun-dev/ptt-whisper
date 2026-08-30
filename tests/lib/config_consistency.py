#!/usr/bin/env python3
"""驗證設定欄位在 Lua 白名單 / README 表格 / config_example.json 三方一致。
這類漂移不會讓程式壞掉，只會讓文件說謊，靠人工 review 抓不可靠。"""
import json, re, sys, pathlib

repo = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else '.')
lua = (repo / 'ptt_whisper.lua').read_text(encoding='utf-8')
readme = (repo / 'README.md').read_text(encoding='utf-8')
cfg = json.loads((repo / 'config_example.json').read_text(encoding='utf-8'))

known = set(re.findall(r'(\w+)\s*=\s*true',
            lua.split('local CONFIG_KNOWN_KEYS = {')[1].split('}')[0]))
doc = set(re.findall(r'^\| `(\w+)` \|',
          readme.split('### 設定欄位說明')[1].split('### 環境變數')[0], re.M))
ex = set(cfg)

problems = []
if known - doc: problems.append(f"README 未記載: {sorted(known - doc)}")
if doc - known: problems.append(f"README 寫了但 Lua 不認得: {sorted(doc - known)}")
if known - ex:  problems.append(f"config_example 未示範: {sorted(known - ex)}")
if ex - known:  problems.append(f"config_example 有 Lua 不認得的 key: {sorted(ex - known)}")

env_doc = set(re.findall(r'\|\s*`(WHISPER_\w+)`\s*\|',
              readme.split('### 環境變數')[1].split('\n---\n')[0]))
sh = (repo / 'transcribe.sh').read_text(encoding='utf-8')
env_used = set(re.findall(r'\$\{(WHISPER_\w+)', sh)) - {'WHISPER_CACHE', 'WHISPER_FALLBACK_MODEL'}
if env_used - env_doc: problems.append(f"環境變數 README 未記載: {sorted(env_used - env_doc)}")
if env_doc - env_used: problems.append(f"環境變數 README 多寫: {sorted(env_doc - env_used)}")

removed = set(re.findall(r'(\w+)\s*=\s*"',
              lua.split('local REMOVED_CONFIG_KEYS = {')[1].split('}')[0]))
if removed & known:
    problems.append(f"同時出現在白名單與已移除清單: {sorted(removed & known)}")

for p in problems:
    print("  " + p)
sys.exit(1 if problems else 0)
