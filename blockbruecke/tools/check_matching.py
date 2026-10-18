#!/usr/bin/env python3
"""Reject the v0.3 lifecycle hazard before building a system extension."""
import pathlib
import plistlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]


def violations(cpp, iig, info):
    errors = []
    code = re.sub(r'/\*.*?\*/|//[^\n]*', '', cpp + '\n' + iig, flags=re.S)
    if re.search(r'\b(Create|Terminate)\s*\(', code):
        errors.append('root must not Create/Terminate a family controller')
    if re.search(r'\b(ivars|init|free)\b', code):
        errors.append('root must not own controller lifetime')
    start = re.search(r'IMPL\(BlockbrueckeWurzel, Start\)\s*\{(.*?)\n\}', cpp, re.S)
    if not start or not re.search(
        r'Start\(provider, SUPERDISPATCH\).*?if \(r != kIOReturnSuccess\) return r;.*?RegisterService\(\)',
        start[1], re.S,
    ):
        errors.append('RegisterService must follow successful super Start')
    personalities = info.get('IOKitPersonalities', {})
    root = personalities.get('Blockbruecke', {})
    child = personalities.get('BlockbrueckeController', {})
    for key, value in {
        'IOClass': 'IOUserService', 'IOProviderClass': 'IOUserResources',
        'IOUserClass': 'BlockbrueckeWurzel', 'BlockbrueckeNub': True,
        'CFBundleIdentifierKernel': 'com.apple.kpi.iokit',
        'IOMatchCategory': '$(PRODUCT_BUNDLE_IDENTIFIER)',
    }.items():
        if root.get(key) != value or (value is True and root.get(key) is not True):
            errors.append(f'root {key} must be {value!r}')
    for key, value in {
        'IOProviderClass': 'IOUserService', 'IOPropertyMatch': {'BlockbrueckeNub': True},
        'IOClass': 'IOUserSCSIParallelInterfaceController', 'IOUserClass': 'Blockbruecke',
        'CFBundleIdentifierKernel': 'com.apple.iokit.IOSCSIParallelFamily',
        'CFBundleIdentifier': '$(PRODUCT_BUNDLE_IDENTIFIER)',
        'IOUserServerName': '$(PRODUCT_BUNDLE_IDENTIFIER)',
    }.items():
        if child.get(key) != value:
            errors.append(f'controller {key} must be {value!r}')
    if len(personalities) != 2 or 'BlockbrueckeController' in root:
        errors.append('controller must be a separate matching personality')
    if info.get('CFBundleShortVersionString') != '0.4' or info.get('CFBundleVersion') != '4':
        errors.append('v0.4 bundle version required')
    return errors


def main():
    errors = violations((ROOT / 'Dext/BlockbrueckeWurzel.cpp').read_text(),
                        (ROOT / 'Dext/BlockbrueckeWurzel.iig').read_text(),
                        plistlib.loads((ROOT / 'Dext/Info.plist').read_bytes()))
    for error in errors:
        print(f'FAIL matching: {error}')
    if not errors:
        print('PASS matching: Nub + separate family personality; no manual lifecycle')
    return bool(errors)


if __name__ == '__main__':
    sys.exit(main())
