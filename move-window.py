#!/usr/bin/env python3
"""Compatibility entry point for a single verified window move."""
import json
import sys
from atlas_backend import move_windows, workspace

try:
    target, destination = sys.argv[1:]
    destination = workspace(destination)
    result = move_windows([{'address': target, 'to': destination}])
    result['workspace'] = destination
    print(json.dumps(result))
except Exception as error:
    print(json.dumps({'ok': False, 'moves': [], 'error': str(error)}))
    sys.exit(1)
