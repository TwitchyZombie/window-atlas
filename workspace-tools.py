#!/usr/bin/env python3
import json
import sys
from atlas_backend import launch, move_windows, restore

try:
    operation, *arguments = sys.argv[1:]
    if operation == 'restore':
        if arguments:
            raise ValueError('Restore requires JSON on standard input')
        data = json.loads(sys.stdin.buffer.readline())
    else:
        payload, = arguments
        data = json.loads(payload)
    if operation == 'move':
        result = move_windows(data)
    elif operation == 'launch':
        result = launch(data)
    elif operation == 'restore':
        result = restore(data['slots'], data.get('openMissing', False))
    else:
        raise ValueError('Unknown operation')
    print(json.dumps(result))
except Exception as error:
    print(json.dumps({'ok': False, 'moves': [], 'error': str(error)}))
    sys.exit(1)
