#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Preserve the pinned daily ramdisk; add only transient 7.3 module handling.

LIUQIN_731_SLOT_SUCCESS_MARKING=1 builds the same ramdisk for a persistent
slot: the base init keeps its A/B slot-success update and the RAM-test marker
that suppresses it is left out.
"""
import gzip, hashlib, json, os, stat, subprocess, sys
from pathlib import Path

here=Path(__file__).resolve().parent
root=here.parents[2]
base=root/'out/kernel-7.3.1/ram/base-unpacked/ramdisk'
dist=Path(os.environ.get('LIUQIN_731_DIST', root/'out/kernel-7.3.1/kernel/dist')).resolve()
out=Path(os.environ.get('LIUQIN_731_RAM_OUT', root/'out/kernel-7.3.1/ram/initramfs')).resolve()
out.mkdir(parents=True,exist_ok=True)
info=json.loads((dist.parent/'build-info.json').read_text())
release=info['kernel_release']
assert release in ('7.3.1-liuqin-exp1', '7.3.1-liuqin-upstream1'), release
activation=(here/'activate-ram.sh').read_text().replace('7.3.1-liuqin-exp1', release).encode()
assert hashlib.sha256(base.read_bytes()).hexdigest()=='454b4c2deb40c867d3bb12702c3da7c840ab6241a0cf94815e0d342c82753eb6'
raw=gzip.decompress(base.read_bytes());entries={};i=0
while i+110<=len(raw):
    assert raw[i:i+6]==b'070701'
    h=[int(raw[i+6+j*8:i+14+j*8],16) for j in range(13)]
    name=raw[i+110:i+110+h[11]-1].decode();i=(i+110+h[11]+3)&~3
    data=raw[i:i+h[6]];i=(i+h[6]+3)&~3
    if name=='TRAILER!!!':break
    name=name.removeprefix('./')
    assert name not in entries,name
    entries[name]=(h,data)
original={k:hashlib.sha256(d).hexdigest() for k,(h,d) in entries.items()}
ino=max(h[0] for h,d in entries.values())+1

def add(name,data=b'',mode=stat.S_IFREG|0o644):
    global ino
    assert name not in entries,name
    entries[name]=([ino,mode,0,0,1,0,len(data),0,0,0,0,len(name.encode())+1,0],data);ino+=1

def parents(name):
    for p in reversed(Path(name).parents):
        text=str(p)
        if text!='.' and text not in entries:add(text,mode=stat.S_IFDIR|0o755)

init=entries['init'][1].decode()
a='storage_switch_persistent_root() {\n'
assert init.count(a)==1
init=init.replace(a,a+'\t. /liuqin-ram/activate.sh || { storage_abort || ufs_safe=false; return 1; }\n',1)
# The RAM-test marker suppresses the A/B slot-success update.  A persistent
# image built with LIUQIN_731_SLOT_SUCCESS_MARKING=1 must keep the base init's
# marking path and must not carry the marker, otherwise every boot spends one
# ABL retry (and A becomes unbootable after about seven boots).
slot_success=os.environ.get('LIUQIN_731_SLOT_SUCCESS_MARKING','0')=='1'
if not slot_success:
	a='\t\tif slot_from_cmdline "$(cat /proc/cmdline)"; then\n'
	assert init.count(a)==1
	init=init.replace(a,'\t\tif [ -f /etc/liuqin-kernel-ram-test ]; then\n\t\t\tlog "RAM TEST: no slot-success metadata update"\n\t\telif slot_from_cmdline "$(cat /proc/cmdline)"; then\n',1)
entries['init']=(entries['init'][0],init.encode())
if not slot_success:
	add('etc/liuqin-kernel-ram-test',(release+'\n').encode())
parents('liuqin-ram/activate.sh')
add('liuqin-ram/activate.sh',activation,stat.S_IFREG|0o755)
add('liuqin-ram/display-cycle.py',(here/'display-cycle.py').read_bytes(),stat.S_IFREG|0o755)
identity={k:info[k] for k in ['kernel_release','gnu_build_id','config_sha256','module_count']}
identity.update(mode='persistent' if slot_success else 'RAM only',
                writes_boot_partitions=False,
                slot_success_marking=slot_success,
                module_overlay='tmpfs',shared_configuration_changes=[])
identity['activation_script_sha256']=hashlib.sha256(activation).hexdigest()
identity['display_cycle_script_sha256']=hashlib.sha256((here/'display-cycle.py').read_bytes()).hexdigest()
add('liuqin-ram/identity.json',(json.dumps(identity,indent=2)+'\n').encode())
modules=dist/'modules'
for p in sorted(modules.rglob('*')):
    name='liuqin-ram/modules/'+str(p.relative_to(modules));parents(name)
    assert not p.is_symlink()
    if p.is_dir():add(name,mode=stat.S_IFDIR|0o755)
    else:add(name,p.read_bytes())
assert sum(n.endswith('.ko') for n in entries)==info['module_count']
changed=[n for n,digest in original.items() if hashlib.sha256(entries[n][1]).hexdigest()!=digest]
assert changed==['init'],changed
result=bytearray()
for name,(h,data) in [*entries.items(),('TRAILER!!!',([ino,0,0,0,1,0,0,0,0,0,0,11,0],b''))]:
    h=list(h);nb=name.encode()+b'\0';h[6]=len(data);h[11]=len(nb)
    result.extend(b'070701'+''.join(f'{x:08x}' for x in h).encode()+nb)
    result.extend(b'\0'*((-len(result))%4));result.extend(data);result.extend(b'\0'*((-len(result))%4))
result.extend(b'\0'*((-len(result))%512))
ramdisk=out/'liuqin-7.3.1-ram.cpio.gz';ramdisk.write_bytes(gzip.compress(result,mtime=0))
(out/'init').write_text(init)
subprocess.run(['sh','-n',str(out/'init')],check=True)
subprocess.run(['sh','-n',str(here/'activate-ram.sh')],check=True)
report={'device_ready':True,'hardware_validated':False,'base_ramdisk_sha256':hashlib.sha256(base.read_bytes()).hexdigest(),'ramdisk_sha256':hashlib.sha256(ramdisk.read_bytes()).hexdigest(),'base_entries':len(original),'new_entries':len(entries)-len(original),'changed_base_entries':changed,'module_count':514,'firmware_and_root_contract':'byte-identical to verified current B ramdisk','mode':'persistent' if slot_success else 'RAM only','temporary_runtime_changes':['tmpfs module view','runtime FPC unit override'],'slot_success_writes':slot_success}
(out/'initramfs-info.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps(report,indent=2))
