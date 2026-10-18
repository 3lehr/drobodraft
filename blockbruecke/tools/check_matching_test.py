#!/usr/bin/env python3
"""Mutation checks for the matching/lifecycle gate; never loads a driver."""
import copy
import os
import plistlib
import subprocess

from check_matching import ROOT, violations

cpp = (ROOT / 'Dext/BlockbrueckeWurzel.cpp').read_text()
iig = (ROOT / 'Dext/BlockbrueckeWurzel.iig').read_text()
info = plistlib.loads((ROOT / 'Dext/Info.plist').read_bytes())
assert not violations(cpp, iig, info), 'baseline must pass'
checks = 0
for bad_cpp in (
    cpp.replace('r = RegisterService();', 'r = Create(this, "BlockbrueckeController", nullptr);'),
    cpp.replace('r = RegisterService();', 'controller->Terminate(0);'),
    cpp.replace('if (r != kIOReturnSuccess) return r;', ''),
    cpp.replace('r = RegisterService();', ''),
    cpp + '\nIOService *ivars;\n',
):
    assert violations(bad_cpp, iig, info), 'unsafe lifecycle passed'
    checks += 1
for personality, key in (
    ('Blockbruecke', 'BlockbrueckeNub'),
    ('Blockbruecke', 'IOProviderClass'),
    ('BlockbrueckeController', 'IOProviderClass'),
    ('BlockbrueckeController', 'IOPropertyMatch'),
    ('BlockbrueckeController', 'IOClass'),
    ('BlockbrueckeController', 'CFBundleIdentifierKernel'),
    ('BlockbrueckeController', 'IOUserServerName'),
):
    bad = copy.deepcopy(info)
    del bad['IOKitPersonalities'][personality][key]
    assert violations(cpp, iig, bad), f'missing {personality}.{key} passed'
    checks += 1
bad = copy.deepcopy(info)
personalities = bad['IOKitPersonalities']
personalities['Blockbruecke']['BlockbrueckeController'] = personalities.pop('BlockbrueckeController')
assert violations(cpp, iig, bad), 'v0.3 nested personality passed'
checks += 1
for args, env in (
    (['gruen', '--id1'], os.environ.copy()),
    (['gruen', '--id2'], dict(os.environ, BB_ID='de.begod.drobo.blockbruecke')),
):
    result = subprocess.run(['bash', str(ROOT / 'tools/bauen.sh'), *args], env=env,
                            capture_output=True, text=True, timeout=5)
    assert result.returncode and 'FAIL v0.4' in result.stdout, result.stdout + result.stderr
    checks += 1
print(f'PASS matching selftest: {checks} unsafe variants rejected')
