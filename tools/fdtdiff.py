import struct, sys, json

def parse(path):
    b=open(path,'rb').read()
    (magic,tot,offst,offs,offr,ver,lcv,bootcpu,szs,szst)=struct.unpack(">10I", b[:40])
    assert magic==0xd00dfeed
    ss=b[offs:offs+szs]; st=b[offst:offst+szst]
    def nm(o):
        e=ss.find(b"\0",o); return ss[o:e].decode('latin1')
    nodes={}; path_=[]; pos=0; cur=None
    while pos<len(st):
        tok,=struct.unpack(">I", st[pos:pos+4]); pos+=4
        if tok==1:
            e=st.find(b"\0",pos); name=st[pos:e].decode('latin1'); pos=(e+4)&~3
            path_.append(name); cur="/"+"/".join(p for p in path_ if p); nodes[cur]={}
        elif tok==2:
            if path_: path_.pop()
        elif tok==3:
            ln,no=struct.unpack(">II", st[pos:pos+8]); pos+=8
            v=st[pos:pos+ln]; pos=(pos+ln+3)&~3
            if cur is not None: nodes[cur][nm(no)]=v
        elif tok==9: break
        else: break
    return nodes

def show(v):
    if len(v)==0: return "(空)"
    if len(v)%4==0 and len(v)<=16:
        return "<"+" ".join("0x%x"%x for x in struct.unpack(">%dI"%(len(v)//4),v))+">"
    try:
        s=v.rstrip(b"\0").decode('utf-8')
        if s.isprintable(): return '"%s"'%s
    except: pass
    return v.hex()

SKIP=set(["phandle","linux,phandle","clock-names","clock-frequency","reg-names","interrupt-names","dma-names","pinctrl-names","fixed-clock"])
def summarize(nodes):
    out={}
    for p,pr in nodes.items():
        out[p]={k:show(v) for k,v in pr.items() if k not in SKIP}
    return out

a=summarize(parse(sys.argv[1])); b=summarize(parse(sys.argv[2]))
la,lb=sys.argv[3],sys.argv[4]
onlya=sorted(set(a)-set(b)); onlyb=sorted(set(b)-set(a)); both=sorted(set(a)&set(b))
print("# 节点数: %s=%d  %s=%d" % (la,len(a), lb,len(b)))
print("\n## 只在 %s 有的节点 (%d)" % (la,len(onlya)))
for p in onlya: print("  "+p)
print("\n## 只在 %s 有的节点 (%d)" % (lb,len(onlyb)))
for p in onlyb: print("  "+p)
print("\n## 共有节点里属性值不同的 (%s)" % len([1 for p in both if a[p]!=b[p]]))
for p in both:
    if a[p]==b[p]: continue
    ka,kb=set(a[p]),set(b[p])
    diffs=[k for k in (ka|kb) if a[p].get(k)!=b[p].get(k)]
    print("\n  %s" % p)
    for k in sorted(diffs):
        va,vb=a[p].get(k),b[p].get(k)
        print("    %-34s %s=%-28s | %s=%s" % (k, la, va if va is not None else "(无)", lb, vb if vb is not None else "(无)"))
