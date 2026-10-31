#!/usr/bin/env python3
"""Capture the installed app and optionally send explicit normalized touches.

The XCTest assertion proves foreground execution only; inspect the exported
screenshots to assess the actual game response. No semantic UI success claim.
"""
import argparse
import datetime
import json
import subprocess
from audit import ROOT

def main():
    p=argparse.ArgumentParser()
    p.add_argument('--device',required=True)
    p.add_argument('--team',required=True)
    p.add_argument('--bundle-id', default='local.factorio.loaderprobe')
    p.add_argument('--tap',nargs=2,type=float,action='append',default=[])
    p.add_argument('--hold',nargs=3,type=float,action='append',default=[])
    p.add_argument('--key',action='append',default=[])
    p.add_argument('--button',action='append',default=[])
    p.add_argument('--actions',help='Ordered JSON array of touch/key/button actions')
    args=p.parse_args()
    actions=[dict(x=x,y=y) for x,y in args.tap]+[dict(x=x,y=y,duration=d) for x,y,d in args.hold]
    for a in actions:
        if not 0<=a['x']<=1 or not 0<=a['y']<=1: p.error('Coordinates must be in [0,1]')
    actions += [dict(key=key) for key in args.key]
    actions += [dict(button=button) for button in args.button]
    if args.actions:
        actions += json.loads(args.actions)
    for a in actions:
        if 'x' in a and not (0<=a['x']<=1 and 0<=a['y']<=1): p.error('Coordinates must be in [0,1]')
    header='#define PROBE_ACTIONS @'+json.dumps(json.dumps(actions))+'\n'
    header+='#define PROBE_BUNDLE_ID @'+json.dumps(args.bundle_id)+'\n'
    (ROOT/'build').mkdir(exist_ok=True)
    (ROOT/'reports').mkdir(exist_ok=True)
    (ROOT/'build/ui-actions.h').write_text(header)
    name='DeviceUI-'+datetime.datetime.now().strftime('%Y%m%d-%H%M%S')
    result=ROOT/'build'/(name+'.xcresult')
    log=ROOT/'reports'/(name+'.log')
    with log.open('w') as f:
        run=subprocess.run(['xcodebuild','-project',str(ROOT/'tests/DeviceSnapshot.xcodeproj'),
            '-scheme','DeviceSnapshot','-sdk','iphoneos','-destination','platform=iOS,id='+args.device,
            '-derivedDataPath',str(ROOT/'build/UITests'/name),'-resultBundlePath',str(result),
            'DEVELOPMENT_TEAM='+args.team,'-allowProvisioningUpdates','test'],stdout=f,stderr=subprocess.STDOUT)
    print(log)
    if run.returncode: print(log.read_text()[-5000:]); raise SystemExit(run.returncode)
    subprocess.run(['xcrun','xcresulttool','export','attachments','--path',str(result),
                    '--output-path',str(ROOT/'reports'/name)],check=True)

if __name__=='__main__':main()
