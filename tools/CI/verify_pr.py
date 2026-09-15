#!/usr/bin/env python3
"""Reject stale approvals before doing expensive work. No credentials are printed."""

import json
import os
from pathlib import Path
import subprocess

REPOSITORY = 'eyenpi/spriglet'


def verify(event_name, event, current):
    expected = event.get('pull_request', {})
    if (event_name != 'pull_request'
            or event.get('repository', {}).get('full_name') != REPOSITORY
            or current.get('number') != expected.get('number')
            or current.get('state') != 'open'
            or current.get('draft') is not False):
        raise ValueError('CI requires a current, open, ready-for-review Spriglet PR')
    for pr in (expected, current):
        if (pr.get('base', {}).get('ref') != 'main'
                or pr.get('base', {}).get('repo', {}).get('full_name') != REPOSITORY):
            raise ValueError('CI only validates PRs targeting this repository main branch')
    for side in ('head', 'base'):
        if (not expected.get(side, {}).get('sha')
                or current.get(side, {}).get('sha') != expected[side]['sha']
                or current[side].get('repo', {}).get('id') != expected[side].get('repo', {}).get('id')):
            raise ValueError('PR code or base changed; update the branch and approve the new run')


def main():
    event = json.loads(Path(os.environ['GITHUB_EVENT_PATH']).read_text())
    number = event.get('pull_request', {}).get('number')
    if type(number) is not int or number <= 0:
        raise ValueError('Expected a numeric PR identifier')
    current = json.loads(subprocess.check_output(
        ['gh', 'api', '--method', 'GET', f'repos/{REPOSITORY}/pulls/{number}'], text=True))
    verify(os.environ['GITHUB_EVENT_NAME'], event, current)
    print(f'PR #{number} still matches the approved run; validation may proceed.')


if __name__ == '__main__':
    main()
