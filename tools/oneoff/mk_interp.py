import sys,struct
src,out,new=sys.argv[1],sys.argv[2],sys.argv[3]
d=bytearray(open(src,'rb').read())
assert d[:4]==b'\x7fELF'
phoff=struct.unpack_from('<Q',d,0x20)[0]; phentsize=struct.unpack_from('<H',d,0x36)[0]; phnum=struct.unpack_from('<H',d,0x38)[0]
for i in range(phnum):
    o=phoff+i*phentsize
    t=struct.unpack_from('<I',d,o)[0]
    if t==3:
        off,va,pa,sz=struct.unpack_from('<QQQQ',d,o+8)
        cur=d[off:off+sz]
        s=cur.split(b'\x00',1)[0]
        nb=new.encode()
        assert len(nb)+1<=sz, 'interp too long: %d > %d'%(len(nb)+1,sz)
        d[off:off+sz]=nb+b'\x00'*(sz-len(nb))
        open(out,'wb').write(d)
        print('interp',s.decode(),'->',new,'size',sz)
        break
else:
    raise SystemExit('no PT_INTERP')
