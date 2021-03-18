#!/usr/bin/python3

# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2021-2021  kcgen <1557255+kcgen@users.noreply.github.com>
#
# pylint: disable=missing-function-docstring
# pylint: disable=too-many-arguments

"""
Recursively checks ZIP files' CUE 'FILE' references

Reports if the referenced FILE:
 - is not found (as currently spelled or named)
 - found, but under different capitalization(s)
 - has spaces or backslashes in its name
 - is excessively long (greater than 16 charaters)

"""

from collections import defaultdict
import glob
import os.path
import sys
import zipfile

def zips():
    return (zipfile.ZipFile(f, 'r') for f in glob.glob('**/*.zip', recursive=True))

def get_contents(zfile):
    contents = zfile.namelist()
    lowercase = [f.lower() for f in contents]
    return (contents, lowercase)

def cues(contents):
    return (f for f in contents if f.lower().endswith('.cue'))

def bins(zfile, cue):
    content = zfile.read(cue).decode('UTF-8')
    prev = str()
    bin_name = str()
    for word in content.split():
        if bin_name.count('"') == 1:
            bin_name += ' '
            bin_name += word
            continue

        if bin_name.count('"') == 2:
            yield bin_name[1:-1]
            bin_name = str()
            continue

        if prev.lower() == 'file':
            bin_name = word

        prev = word

def assess(zfile, standard, lowercase, cue, bin_name, issues):
    cue_path = os.path.dirname(cue)
    bin_path = os.path.join(cue_path, bin_name)

    if bin_path in standard:
        critical = None
    else:
        critical = 'has mismatched case(s)' if bin_path.lower() in lowercase else 'is missing'

    warnings = list()
    if '\\' in bin_path:
        warnings.append('contains backslashes')
    if ' ' in bin_name:
        warnings.append('contains spaces')
    if len(bin_name) > 16:
        warnings.append('is excessively long')

    if critical or warnings:
        record = cue, bin_path, critical, warnings
        issues[os.path.basename(zfile.filename)].append(record)

def print_progress(size):
    unit = ''
    for increment in ['','KiB','MiB','GiB','TiB','PiB']:
        if abs(size) < 1024.0:
            unit = increment
            break
        size /= 1024.0
    sys.stdout.write('Scanned: %3.1f %s\r' % (size, unit))
    sys.stdout.flush()

def scan_zips():
    size = 0
    issues = defaultdict(list)
    for zfile in zips():
        contents, lowercase = get_contents(zfile)
        for cue in cues(contents):
            for bin_name in bins(zfile, cue):
                assess(zfile, contents, lowercase, cue, bin_name, issues)

        size += os.path.getsize(zfile.filename)
        print_progress(size)
    return issues

def print_issues(issues):
    zfiles_with_issues = sorted(issues, key=str.casefold)
    for zfile in zfiles_with_issues:
        print(zfile)
        for record in issues[zfile]:
            cue, bin_name, critical, warnings = record
            is_last = (record is issues[zfile][-1])
            if critical:
                cue_name = os.path.basename(cue)
                div = '`' if is_last and not warnings else '|'
                print(f'    {div}- {cue_name} refers to "{bin_name}", but {critical}')
            if warnings:
                warning_str = ' and '.join(warnings)
                div = '`' if is_last else '|'
                print(f'    {div}- The "{bin_name}" {warning_str}')
        print('')

def main():
    issues = scan_zips()
    print_issues(issues)

if __name__ == "__main__":
    main()
