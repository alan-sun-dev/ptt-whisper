#!/usr/bin/env python3
"""掃描 shell 檔案裡「$VAR 緊接非 ASCII 字元」的寫法。

bash 解析 $VAR 時會把後面的多位元組字元一起吃進變數名。例如：

    _t_bad "沒有產出任何斷言（exit=$lua_rc）"

bash 看到的變數名是 lua_rc 加上全形括號的位元組，在 set -u 下直接
"unbound variable" 中止腳本。寫成 ${lua_rc} 即可。

這種 bug 只在該行真的被執行時才會爆，bash -n 抓不到——正是最容易
漏到使用者手上的那一類。
"""
import re, sys, pathlib

pat = re.compile(r'\$[A-Za-z_][A-Za-z0-9_]*(?=[^\x00-\x7f])')
bad = []
for p in sys.argv[1:]:
    for n, line in enumerate(pathlib.Path(p).read_text(encoding='utf-8').split('\n'), 1):
        if line.lstrip().startswith('#'):
            continue
        for m in pat.finditer(line):
            bad.append((p, n, m.group(0), line.strip()[:90]))

for p, n, v, l in bad:
    print(f"  {p}:{n}  {v}  →  {l}")
sys.exit(1 if bad else 0)
