#!/usr/bin/env python
"""Minimal jq shim for testing workflow-guard.sh on machines without jq.

Supports exactly the invocation shapes the guard uses:
  jq -r '.tool_name // empty'
  jq -r '.tool_input.command // empty'
  jq -r '.tool_input.file_path // .tool_input.notebook_path // empty'
  jq -n --arg reason "..." '{object: {construction: $reason}}'

Anything else exits 3 so misuse is loud rather than silently wrong.
"""
import json
import re
import sys


def main():
    args = sys.argv[1:]
    null_input = False
    raw = False
    variables = {}
    prog = None
    i = 0
    while i < len(args):
        a = args[i]
        if a == '-n':
            null_input = True
        elif a == '-r':
            raw = True
        elif a == '--arg':
            variables[args[i + 1]] = args[i + 2]
            i += 2
        elif a.startswith('-'):
            sys.stderr.write('jq_shim: unsupported flag %s\n' % a)
            return 3
        else:
            prog = a
        i += 1

    if prog is None:
        sys.stderr.write('jq_shim: no program given\n')
        return 3

    if null_input:
        # Object-construction program: quote bare keys first (the program text
        # contains no colons inside strings), then substitute $vars as JSON.
        if not prog.lstrip().startswith('{'):
            sys.stderr.write('jq_shim: -n only supports object construction\n')
            return 3
        p = re.sub(r'([A-Za-z_][A-Za-z0-9_]*)\s*:', r'"\1":', prog)
        for k, v in variables.items():
            p = p.replace('$' + k, json.dumps(v))
        try:
            obj = json.loads(p)
        except ValueError as e:
            sys.stderr.write('jq_shim: cannot evaluate program: %s\n' % e)
            return 3
        print(json.dumps(obj, indent=2))
        return 0

    # Path expression with // alternatives over stdin JSON.
    try:
        data = json.load(sys.stdin)
    except ValueError:
        sys.stderr.write('jq_shim: invalid JSON input\n')
        return 4

    result = None
    for alt in prog.split('//'):
        alt = alt.strip()
        if alt == 'empty':
            result = None
            break
        if not alt.startswith('.'):
            sys.stderr.write('jq_shim: unsupported expression %r\n' % alt)
            return 3
        cur = data
        found = True
        for part in alt.lstrip('.').split('.'):
            if isinstance(cur, dict) and part in cur:
                cur = cur[part]
            else:
                found = False
                break
        if found and cur is not None:
            result = cur
            break

    if result is None:
        return 0  # 'empty' -> no output
    if raw and isinstance(result, str):
        print(result)
    else:
        print(json.dumps(result))
    return 0


if __name__ == '__main__':
    sys.exit(main())
