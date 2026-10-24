#!/usr/bin/env python3
"""Execute the shipped device shell against isolated NAND/environment command doubles.
No SSH, device files, root privileges, or real reboot commands are used.
"""
from pathlib import Path
import hashlib, json, os, re, subprocess, tempfile

SOURCE = (Path(__file__).resolve().parents[1] / 'Sources/XiaoaiCore/OTADeviceAgent.swift').read_text().split('#"""\n', 1)[1].rsplit('\n"""#', 1)[0]
ORIGINAL = re.search(r"ORIGINAL_PREBOOT='([^']*)'", SOURCE)[1]
TRIAL = re.search(r"TRIAL_PREBOOT='([^']*)'", SOURCE)[1]
MOCK = r'''#!/usr/bin/env python3
import os,sys,json,hashlib,shutil
from pathlib import Path
base=Path(os.environ['FIXTURE']); name=Path(sys.argv[0]).name; args=sys.argv[1:]
if name=='fw_env':
 p=base/'env.json'; e=json.loads(p.read_text())
 if args[0]=='-g': print(e.get(args[1],''))
 else:
  with (base/'env-writes').open('a') as f: f.write(args[1]+'='+args[2]+'\n')
  if os.environ.get('ENV_FAIL')==args[1] and not (base/'env-failed').exists():
   (base/'env-failed').touch(); sys.exit(1)
  e[args[1]]=args[2];p.write_text(json.dumps(e))
elif name=='id': print('0')
elif name=='uci': print('LX06' if args[-1].endswith('HARDWARE') else '1.94.13')
elif name=='mtd':
 with (base/'writes').open('a') as f: f.write(args[-1]+'\n')
 if os.environ.get('WRITE_FAIL')==args[-1]: sys.exit(1)
 n={'boot0':2,'boot1':3,'system0':4,'system1':5}[args[-1]]
 p=base/('mtdblock'+str(n));shutil.copyfile(args[1],p)
 if os.environ.get('CORRUPT')==args[-1]:
  with p.open('r+b') as f: f.write(b'BAD')
elif name=='sha256sum':
 data=Path(args[0]).read_bytes() if args else sys.stdin.buffer.read();print(hashlib.sha256(data).hexdigest()+'  -')
elif name=='reboot': (base/'rebooted').touch()
elif name=='sleep': pass
elif name=='sync': pass
elif name=='pidof': print('123')
else: sys.exit(99)
'''
checks=0
with tempfile.TemporaryDirectory(prefix='xiaoai-ota-agent-') as folder:
    base=Path(folder); bin=base/'bin'; bin.mkdir()
    for cmd in ['fw_env','id','uci','mtd','sha256sum','reboot','sleep','sync','pidof']:
        p=bin/cmd;p.write_text(MOCK);p.chmod(0o700)
    source=SOURCE.replace('/data/xiaoai-ota',str(base/'data')).replace('/tmp/xiaoai-ota',str(base/'tmp')).replace('/dev/mtdblock',str(base/'mtdblock')).replace('/proc/mounts',str(base/'mounts')).replace('/proc/sys/kernel/random/boot_id',str(base/'boot-id'))
    script=base/'agent.sh';script.write_text(source)
    env=dict(os.environ,PATH=str(bin)+':'+os.environ['PATH'],FIXTURE=folder)
    kernel=b'K'*6291456;root=b'R'*4096
    kh=hashlib.sha256(kernel).hexdigest();rh=hashlib.sha256(root).hexdigest()
    def reset():
        import shutil
        for p in base.iterdir():
            if p.name not in ['bin','agent.sh']:
                shutil.rmtree(p) if p.is_dir() else p.unlink()
        (base/'env.json').write_text(json.dumps(dict(boot_part='boot0',board_id='1',preboot=ORIGINAL,boot_failcnt='0')))
        (base/'mounts').write_text(str(base/'mtdblock4')+' / squashfs ro 0 0\n')
        (base/'boot-id').write_text('532ec08f-7cb5-438c-a762-0c3e6a094d01')
        for n in range(2,6): (base/f'mtdblock{n}').write_bytes(b'ORIGINAL'+bytes([n]))
        stage=base/'tmp'/'job-test';stage.mkdir(parents=True)
        (stage/'boot.img').write_bytes(kernel);(stage/'root.squashfs').write_bytes(root);(stage/'agent.sh').write_text(source)
    def execute(*args,ok=True,**extra):
        global checks
        r=subprocess.run(['/bin/sh',str(script),*args],env=dict(env,**extra),capture_output=True,text=True,timeout=20)
        assert (r.returncode==0)==ok,(args,r.stdout,r.stderr)
        checks+=1;return r
    def apply(**kw): return execute('apply','job-test',rh,str(len(root)),kh,**kw)
    def boot():
        e=json.loads((base/'env.json').read_text());e.update(xw_ota_state='trying',boot_part='boot1');(base/'env.json').write_text(json.dumps(e))
        (base/'mounts').write_text(str(base/'mtdblock5')+' / squashfs ro 0 0\n')
    reset();(base/'tmp/job-test/root.squashfs').write_bytes(b'X'*4096);apply(ok=False)
    assert not (base/'writes').exists() and json.loads((base/'env.json').read_text())['boot_part']=='boot0'
    for failure in [dict(WRITE_FAIL='boot1'),dict(WRITE_FAIL='system1'),dict(CORRUPT='system1'),dict(ENV_FAIL='boot_part')]:
        reset();apply(ok=False,**failure)
        e=json.loads((base/'env.json').read_text());assert e['boot_part']=='boot0' and e['preboot']==ORIGINAL
        assert (base/'mtdblock2').read_bytes()==b'ORIGINAL\x02' and (base/'mtdblock4').read_bytes()==b'ORIGINAL\x04'
    reset();apply();e=json.loads((base/'env.json').read_text());assert e['boot_part']=='boot1' and e['xw_ota_state']=='armed'
    assert (base/'writes').read_text()=='boot1\nsystem1\n'
    writes=(base/'env-writes').read_text().splitlines();assert writes[-1]=='boot_part=boot1'
    boot();execute('confirm','wrong-job',ok=False);execute('confirm','job-test',ok=False)
    (base/'tmp-watch-ready').write_text(str(os.getpid()));execute('confirm','job-test')
    assert json.loads((base/'env.json').read_text())['preboot']==ORIGINAL
    execute('rollback','job-test');assert json.loads((base/'env.json').read_text())['boot_part']=='boot0'
    reset();apply();boot();(base/'rebooted').unlink(missing_ok=True);execute('boot-watch');assert (base/'rebooted').exists()
    # A previous job's rolled-back environment must never override a new writing/trial state.
    reset();apply()
    e=json.loads((base/'env.json').read_text());e.update(boot_part='boot0',xw_ota_state='rolled_back',xw_ota_job='older-job');(base/'env.json').write_text(json.dumps(e))
    result=execute('status');assert 'XW_PHASE=trial' in result.stdout and 'XW_PHASE=rolled_back' not in result.stdout
    state=base/'data/state';state.write_text(state.read_text().replace('phase=trial','phase=writing'))
    (base/'tmp.lock').mkdir();result=execute('status');assert 'XW_PHASE=writing' in result.stdout
    (base/'tmp.lock').rmdir();result=execute('status');assert 'XW_PHASE=failed' in result.stdout
    execute('finish-rollback','job-test',ok=False)
    e=json.loads((base/'env.json').read_text());e['preboot']=ORIGINAL;(base/'env.json').write_text(json.dumps(e))
    apply() # A reboot-cleared writer lock permits a fresh transaction after hash revalidation.
    # Exercise the real U-Boot hush script with its supported shell subset.
    for state,slot,want_state,want_slot in [('armed','boot1','trying','boot1'),('trying','boot1','rolled_back','boot0'),('armed','boot0','rolled_back','boot0'),('committed','boot1','committed','boot1')]:
        shell='setenv() { export "$1=$2"; }; saveenv() { :; }; run() { :; }; '+TRIAL+' printf "%s %s %s" "$xw_ota_state" "$boot_part" "$boot_failcnt"'
        r=subprocess.run(['/bin/sh','-c',shell],env=dict(env,xw_ota_state=state,boot_part=slot,xw_ota_previous='boot0',xw_ota_target='boot1',boot_failcnt='0'),capture_output=True,text=True,check=True)
        assert r.stdout==f'{want_state} {want_slot} 0',r.stdout;checks+=1
print(f'PASS {checks} device-agent and boot-script checks')
