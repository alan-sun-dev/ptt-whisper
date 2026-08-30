import re,sys
def strip(src):
    out=[];i=0;n=len(src)
    while i<n:
        c=src[i]
        if c=='-' and src[i:i+2]=='--':
            m=re.match(r'--\[(=*)\[',src[i:])
            if m:
                close=']'+m.group(1)+']'
                j=src.find(close,i)
                i=n if j<0 else j+len(close); out.append(' ')
            else:
                j=src.find('\n',i); i=n if j<0 else j; out.append(' ')
            continue
        m=re.match(r'\[(=*)\[',src[i:])
        if m:
            close=']'+m.group(1)+']'
            j=src.find(close,i)
            i=n if j<0 else j+len(close); out.append(' ')
            continue
        if c in '"\'':
            q=c;i+=1
            while i<n and src[i]!=q:
                i+= 2 if src[i]=='\\' else 1
            i+=1; out.append(' '); continue
        out.append(c); i+=1
    return ''.join(out)

OPEN={'function','then','do','repeat'}
CLOSE={'end','until'}
def check(path):
    src=strip(open(path,encoding='utf-8').read())
    depth=0; stack=[]; errs=[]
    for ln,line in enumerate(src.split('\n'),1):
        for tok in re.findall(r'\b[A-Za-z_]\w*\b',line):
            if tok=='elseif': depth-=1
            elif tok in OPEN:
                depth+=1; stack.append((ln,tok))
            elif tok in CLOSE:
                depth-=1
                if stack: stack.pop()
                else: errs.append(f"  line {ln}: 多餘的 '{tok}'")
            if depth<0: errs.append(f"  line {ln}: depth 轉負（多一個 end/until）"); depth=0; 
    return depth,stack,errs
for path in sys.argv[1:]:
    d,st,errs=check(path)
    print(f"{path}: 最終 depth={d} {'✓ 平衡' if d==0 and not errs else '✗ 不平衡'}")
    for e in errs[:5]: print(e)
    if d!=0:
        for ln,tok in st[-3:]: print(f"  未關閉: line {ln} '{tok}'")
