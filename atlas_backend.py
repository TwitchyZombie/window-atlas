"""Verified desktop operations. Arguments are data; only installed launchers run."""
import json
import re
import subprocess
import time


def run(*args):
    result = subprocess.run(['hyprctl', *args], capture_output=True, text=True, timeout=4, check=True)
    return result.stdout


def clients():
    return json.loads(run('-j', 'clients'))


def address(value):
    value = str(value)
    if not value.startswith('0x'):
        value = '0x' + value
    if not re.fullmatch(r'0x[0-9a-fA-F]+', value):
        raise ValueError('Invalid window address')
    return value.lower()


def workspace(value):
    if isinstance(value, bool) or not re.fullmatch(r'[1-9][0-9]*', str(value)) or int(value) > 2147483647:
        raise ValueError('Invalid desktop number')
    return int(value)


def move_windows(requests):
    if not isinstance(requests, list) or not requests or len(requests) > 256:
        raise ValueError('Choose between 1 and 256 windows')
    # Validate the whole request before dispatching any operation.
    jobs = [dict(item, address=address(item['address']), to=workspace(item['to'])) for item in requests]
    if len({item['address'] for item in jobs}) != len(jobs):
        raise ValueError('Duplicate window in move')
    moved, errors = [], []
    for item in jobs:
        try:
            current = next((c for c in clients() if c['address'].lower() == item['address']), None)
            if current is None:
                raise ValueError('A selected window has closed')
            if item.get('pid') is not None and int(item['pid']) != current['pid']:
                raise ValueError('That window has been replaced')
            original = current['workspace']['id']
            if original < 1:
                raise ValueError('Special workspace windows cannot be moved here')
            if original == item['to']:
                continue
            run('eval', 'hl.dispatch(hl.dsp.window.move({window="address:' + item['address'] + '",workspace="' + str(item['to']) + '",follow=false}))')
            for _ in range(20):
                if any(c['address'].lower() == item['address'] and c['workspace']['id'] == item['to'] for c in clients()):
                    moved.append({'address': item['address'], 'from': original, 'to': item['to'], 'pid': current['pid']})
                    break
                time.sleep(.05)
            else:
                raise RuntimeError('Window did not reach its destination')
        except Exception as error:
            errors.append(str(error))
    return {'ok': not errors, 'moves': moved, 'error': '; '.join(dict.fromkeys(errors))}


def launch(spec):
    desktop_id = str(spec['desktopId'])
    if not desktop_id or desktop_id.startswith('-') or '/' in desktop_id or '\x00' in desktop_id:
        raise ValueError('Invalid installed app launcher')
    destination = workspace(spec['workspace'])
    before = {c['address'] for c in clients()}
    # gtk-launch resolves installed desktop files and handles their Exec field.
    classes = {str(c).lower() for c in spec.get('classes', []) if c}
    if not classes:
        raise ValueError('App has no window identity')
    process = subprocess.Popen(['gtk-launch', desktop_id], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for _ in range(100):
        for c in clients():
            if c['address'] in before:
                continue
            identities = {str(c.get(k, '')).lower() for k in ('class', 'initialClass')}
            if identities & classes:
                result = move_windows([{'address': c['address'], 'to': destination, 'pid': c['pid']}])
                result['address'] = c['address']
                result['workspace'] = destination
                return result
        if process.poll() not in (None, 0):
            raise RuntimeError('The app launcher failed')
        time.sleep(.1)
    raise RuntimeError('No new app window appeared; the app may have reused an existing window')


def restore(slots, open_missing=False):
    if not isinstance(slots, list) or len(slots) > 256:
        raise ValueError('Invalid saved arrangement')
    # Validate all desktop numbers before changing anything.
    for slot in slots:
        workspace(slot['workspace'])
    used, moves, missing, errors = set(), [], [], []
    for slot in slots:
        identities = {str(c).lower() for c in slot.get('classes', []) if c}
        candidates = [c for c in clients() if c['address'] not in used and identities & {str(c.get(k, '')).lower() for k in ('class', 'initialClass')}]
        candidates.sort(key=lambda c: (c.get('title', '') != slot.get('title', ''), c['workspace']['id'] != slot['workspace'], c['address']))
        if candidates:
            current = candidates[0]
            used.add(current['address'])
            result = move_windows([{'address': current['address'], 'to': slot['workspace'], 'pid': current['pid']}])
            moves.extend(result['moves'])
            if not result['ok']:
                errors.append(result['error'])
        elif open_missing and slot.get('desktopId'):
            try:
                result = launch(slot)
                used.add(result['address'])
                moves.extend(result['moves'])
                if not result['ok']:
                    errors.append(result['error'])
            except Exception as error:
                errors.append(str(error))
        else:
            missing.append(slot.get('name') or 'Unknown app')
    return {'ok': not errors, 'moves': moves, 'missing': missing, 'error': '; '.join(dict.fromkeys(errors))}
