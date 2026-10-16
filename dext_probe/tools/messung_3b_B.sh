#!/bin/bash
# Stufe 3b Variante B: nach Neustecken (Dext 3.3/9, Timer +60 s, 6 Schuesse alle 12 s: Suspend->CDB->Resume).
# Haengt disk6s2/disk6s3 (nur CF-Karte) 35 s nach Dext-Start aus, protokolliert mount je Sekunde, danach Log roh.
set -u
S=$(date "+%Y-%m-%d %H:%M:%S")
echo "warte auf Dext-Start nach $S"
for i in $(seq 1 300); do
  /usr/bin/log show --start "$S" --info --debug --predicate 'eventMessage CONTAINS "MaxWriteProbe: 3b Timer gesetzt"' --style compact 2>/dev/null | grep -q "Timer gesetzt" && break; sleep 1
done
T0=$(date +%s); echo "Dext gestartet (T0=$T0)"
( for i in $(seq 1 120); do echo "$(date +%T) $(mount | grep -E 'disk6s[23]' | awk '{print $3}' | tr '\n' ' ')"; sleep 1; done ) > /tmp/mount_samples_3b.txt &
sleep 30
echo "mount vorher:"; mount | grep disk6
diskutil unmount /dev/disk6s3; diskutil unmount /dev/disk6s2
echo "mount nach unmount:"; mount | grep disk6
sleep 90
echo "mount nach Messung:"; mount | grep disk6
diskutil list disk6
echo ---LOG---
/usr/bin/log show --start "$S" --info --debug --predicate 'eventMessage CONTAINS "MaxWriteProbe"' --style compact | grep -v "log\["
echo ---MOUNT-SAMPLES (Wechsel)---
uniq -f1 /tmp/mount_samples_3b.txt
