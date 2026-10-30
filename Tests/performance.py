"""Measure the installed helper, then restore its original playback mode."""
import ctypes
import json
from pathlib import Path
import subprocess
import os
import time

support = Path.home() / 'Library/Application Support/LiveWallpaper'
binary = Path.home() / 'Applications/Live Wallpaper.app/Contents/MacOS/LiveWallpaper'
libproc = ctypes.CDLL('/usr/lib/libproc.dylib', use_errno=True)

class Usage(ctypes.Structure):
    _fields_ = [('uuid', ctypes.c_uint8 * 16)] + [(name, ctypes.c_uint64) for name in (
        'user', 'system', 'idle_wakeups', 'interrupt_wakeups', 'pageins', 'wired',
        'resident', 'footprint', 'started', 'exited')]

def status():
    subprocess.run([str(binary), '--refresh-status'], check=True)
    time.sleep(0.25)
    return json.loads((support/'status.json').read_text())

def usage(pid):
    value = Usage()
    if libproc.proc_pid_rusage(pid, 0, ctypes.byref(value)):
        raise OSError(ctypes.get_errno(), 'proc_pid_rusage')
    return value

initial = status()
decoder_pid = int(os.environ.get('DECODER_PID', '0'))
duration = float(os.environ.get('SAMPLE_SECONDS', '15'))
results = []
try:
    for mode in ['always', 'paused', 'visible']:
        subprocess.run([str(binary), '--mode', mode], check=True)
        time.sleep(2)
        before = status()
        a = usage(before['pid'])
        decoder_a = usage(decoder_pid) if decoder_pid else None
        start = time.monotonic()
        time.sleep(duration)
        b = usage(before['pid'])
        decoder_b = usage(decoder_pid) if decoder_pid else None
        elapsed = time.monotonic()-start
        after = status()
        assert before['pid'] == after['pid'], 'Process restarted during sample'
        assert after['mode'] == mode, 'Mode change was not applied'
        cpu = (b.user+b.system-a.user-a.system)/1e9/elapsed*100
        row = dict(mode=mode, wall_seconds=elapsed, cpu_percent_one_core=cpu,
                   resident_mib=b.resident/2**20, footprint_mib=b.footprint/2**20,
                   idle_wakeups_per_second=(b.idle_wakeups-a.idle_wakeups)/elapsed,
                   metadata_queries=after['metadataQueries']-before['metadataQueries'],
                   before=before, after=after)
        if decoder_a is not None:
            row['decoder_pid'] = decoder_pid
            row['decoder_cpu_percent_one_core'] = (decoder_b.user+decoder_b.system-decoder_a.user-decoder_a.system)/1e9/elapsed*100
            row['decoder_footprint_mib'] = decoder_b.footprint/2**20
        if mode == 'paused':
            assert after['playingPlayers'] == 0
            assert not after['visibilityTimerActive']
            assert row['metadata_queries'] == 0
        if mode == 'always':
            assert not after['visibilityTimerActive']
            assert row['metadata_queries'] == 0
            assert all(s['playerRate'] == 1 for s in after['screens'] if s['assetID'])
        results.append(row)
        print(json.dumps({k:v for k,v in row.items() if k not in ('before','after')}),flush=True)
finally:
    subprocess.run([str(binary),'--mode',initial['mode']],check=True)

target = Path(__file__).resolve().parent.parent/('performance-with-decoder.json' if decoder_pid else 'performance-results.json')
target.write_text(json.dumps(results,indent=2))
print('Saved',target,flush=True)
