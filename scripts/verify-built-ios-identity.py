#!/usr/bin/env python3
"""Inspect an already built .app, without launching or installing it."""
import argparse,json,plistlib
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('--app',type=Path,required=True);p.add_argument('--configuration',choices=['Debug','Release'],required=True);a=p.parse_args()
root=Path(__file__).resolve().parents[1]
for target,info,bundle,name in json.loads((root/'scripts/ios-identities.json').read_text()):
 app=a.app if target!='TailViewLiveActivity' else a.app/'PlugIns/TailViewLiveActivity.appex'
 d=plistlib.loads((app/'Info.plist').read_bytes())
 if a.configuration=='Debug':
  bundle=bundle.replace('.LiveActivity','.dev.LiveActivity') if target=='TailViewLiveActivity' else bundle+'.dev';name+=' Dev'
 assert d['CFBundleIdentifier']==bundle,(target,d['CFBundleIdentifier'])
 assert d['CFBundleDisplayName']==name,(target,d['CFBundleDisplayName'])
 if target=='BackgroundTranscriber':assert d['BGTaskSchedulerPermittedIdentifiers']==[bundle+'.transcription']
 if target!='TailViewLiveActivity':
  names=[d.get(k,{}).get('CFBundlePrimaryIcon',{}).get('CFBundleIconName') for k in ['CFBundleIcons','CFBundleIcons~ipad']]
  expected='AppIcon-Dev' if a.configuration=='Debug' else 'AppIcon' if target=='TailViewIOS' else None
  assert expected in names,(target,'icon',names,expected)
 print('PASS:',target,a.configuration,bundle,name)
