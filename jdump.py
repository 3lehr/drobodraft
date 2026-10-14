import struct,sys
f=open(sys.argv[1],'rb'); f.seek(1024); h=f.read(512)
jib=struct.unpack('>I',h[12:16])[0]; bs=struct.unpack('>I',h[40:44])[0]
f.seek(jib*bs); j=f.read(512); off,size=struct.unpack('>QQ',j[36:52])
f.seek(off); jh=f.read(512); m,e,start,end,sz,blh,chk,jhs=struct.unpack('<IIQQQIII',jh[:44])
f.seek(off+start); b=f.read(blh); mx,num,used,ck,fl=struct.unpack('<HHIII',b[:16])
pos=start+blh   # Datenbloecke folgen dem Blocklistenkopf
for i in range(1,num):
    bnum,bsz,nxt=struct.unpack('<QII',b[16+i*16:32+i*16])
    f.seek(off+pos); data=f.read(bsz); pos+=bsz
    f.seek(bnum*512); disk=f.read(bsz)
    print('blk',i,'byte',bnum*512,'size',bsz,'journal==disk(vorher)?',data==disk)
    open(sys.argv[2]+'.blk%d'%i,'wb').write(data)
