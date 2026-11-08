import unittest
from unittest.mock import patch
import atlas_backend as backend


def client(addr='0xabc', desktop=1, pid=7, app='test.app', title='Test'):
    return {'address': addr, 'workspace': {'id': desktop}, 'pid': pid, 'class': app, 'initialClass': app, 'title': title}


class BackendTests(unittest.TestCase):
    def test_validates_entire_batch_before_moving(self):
        with patch.object(backend, 'run') as run:
            with self.assertRaises(ValueError):
                backend.move_windows([{'address': 'abc', 'to': 2}, {'address': 'def', 'to': '2); evil()'}])
            run.assert_not_called()

    def test_pid_guard_prevents_moving_replacement(self):
        with patch.object(backend, 'clients', return_value=[client(pid=8)]), patch.object(backend, 'run') as run:
            result = backend.move_windows([{'address': 'abc', 'to': 2, 'pid': 7}])
            self.assertFalse(result['ok'])
            self.assertEqual(result['moves'], [])
            run.assert_not_called()

    def test_partial_move_retains_undo_information(self):
        states = [[client()], [client(desktop=2)], [client(desktop=2)]]
        with patch.object(backend, 'clients', side_effect=states), patch.object(backend, 'run'):
            result = backend.move_windows([{'address': 'abc', 'to': 2}, {'address': 'def', 'to': 2}])
            self.assertFalse(result['ok'])
            self.assertEqual(result['moves'], [{'address': '0xabc', 'from': 1, 'to': 2, 'pid': 7}])

    def test_restore_matches_distinct_windows_by_title(self):
        slots = [{'classes': ['test.app'], 'title': title, 'workspace': desk} for title, desk in [('B', 2), ('A', 3)]]
        with patch.object(backend, 'clients', return_value=[client(title='A'), client(addr='0xdef', title='B')]), patch.object(backend, 'move_windows', return_value={'ok': True, 'moves': []}) as move:
            backend.restore(slots)
            self.assertEqual([call.args[0][0]['address'] for call in move.call_args_list], ['0xdef', '0xabc'])

    def test_restore_reports_unlaunchable_missing_app(self):
        with patch.object(backend, 'clients', return_value=[]):
            result = backend.restore([{'classes': ['gone'], 'workspace': 2, 'name': 'Gone'}], True)
            self.assertEqual(result['missing'], ['Gone'])

    def test_launcher_refuses_missing_identity_before_launch(self):
        with patch.object(backend, 'clients', return_value=[]), patch.object(backend.subprocess, 'Popen') as launch:
            with self.assertRaises(ValueError):
                backend.launch({'desktopId': 'app', 'workspace': 2, 'classes': []})
            launch.assert_not_called()

    def test_launcher_never_moves_preexisting_window(self):
        fake_process = unittest.mock.Mock()
        fake_process.poll.return_value = 0
        with patch.object(backend, 'clients', return_value=[client()]), patch.object(backend.subprocess, 'Popen', return_value=fake_process), patch.object(backend.time, 'sleep'), patch.object(backend, 'move_windows') as move:
            with self.assertRaises(RuntimeError):
                backend.launch({'desktopId': 'app', 'workspace': 2, 'classes': ['test.app']})
            move.assert_not_called()


if __name__ == '__main__':
    unittest.main()
