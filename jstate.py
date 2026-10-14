import struct,sys
f=open(sys.argv[1],'rb'); f.seek(1024); h=f.read(512)
attr=struct.unpack('>I',h[4:8])[0]; jib=struct.unpack('>I',h[12:16])[0]; bs=struct.unpack('>I',h[40:44])[0]
f.seek(jib*bs); j=f.read(512); off,size=struct.unpack('>QQ',j[36:52])
f.seek(off); jh=f.read(64); m,e,start,end,size_,blh,chk,jhs=struct.unpack('<IIQQQIII',jh[:44])
print("attr=%#x unmounted=%d journal start=%d end=%d %s" % (attr, bool(attr&0x100), start, end, "LEER" if start==end else "NICHT-LEER"))
