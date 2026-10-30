import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

from cinespice_bot.config import ConfigurationError, Settings
from cinespice_bot.__main__ import main
from cinespice_bot.protocol import Signer, generate_key
from cinespice_bot.storage import Store


class ConfigurationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='bot config ')
        self.addCleanup(self.temp.cleanup)
        previous = Path.cwd()
        os.chdir(self.temp.name)
        self.addCleanup(os.chdir, previous)
        self.env = {
            'BOT_TOKEN': '123456:synthetic-secret',
            'BOT_USERNAME': 'synthetic_bot',
            'BOT_USER_ID': '123456',
            'PAID_GROUP_ID': '-1001',
            'ADMIN_IDS': '42',
            'CONTACT_URL': 'https://t.me/contact_group',
        }

    def write_env(self, extra=''):
        Path('.env').write_text('\n'.join(f'{key}={value}' for key, value in self.env.items()) + '\n' + extra,
                               encoding='utf-8')

    def test_valid_environment_preserves_defaults(self):
        with patch.dict(os.environ, self.env, clear=True):
            settings = Settings.load()
        self.assertEqual(settings.username, 'synthetic_bot')
        self.assertEqual(settings.channels, ())
        self.assertEqual(settings.ttl, 3600)
        self.assertEqual(settings.key_path, Path('state/signing-key.pem'))

    def test_announcement_channel_must_be_an_optional_configured_channel(self):
        channels = json.dumps([{'id': -1002, 'title': 'Updates', 'url': 'https://t.me/community'}])
        with patch.dict(os.environ, dict(self.env, REQUIRED_CHANNELS=channels, ANNOUNCEMENT_CHANNEL_ID='-1002'), clear=True):
            self.assertEqual(Settings.load().announcement_channel, -1002)
        with patch.dict(os.environ, dict(self.env, REQUIRED_CHANNELS=channels, ANNOUNCEMENT_CHANNEL_ID='-9999'), clear=True):
            with self.assertRaisesRegex(ValueError, 'ANNOUNCEMENT_CHANNEL_ID'): Settings.load()

    def test_missing_and_empty_required_variables_are_named_without_values(self):
        for name in self.env:
            for value in (None, '', '   '):
                with self.subTest(name=name, value=value):
                    env = dict(self.env)
                    if value is None:
                        del env[name]
                    else:
                        env[name] = value
                    with patch.dict(os.environ, env, clear=True):
                        with self.assertRaises(ConfigurationError) as caught:
                            Settings.load()
                    self.assertIn(name, str(caught.exception))
                    self.assertNotIn('synthetic-secret', str(caught.exception))

    def test_incomplete_channel_objects_report_fields_without_input(self):
        channel = {'id': -1002, 'title': 'Private synthetic title', 'url': 'https://t.me/community'}
        invalid = [None, [], 'private synthetic input']
        invalid += [{key: value for key, value in channel.items() if key != missing} for missing in channel]
        for value in invalid:
            with self.subTest(value=value):
                env = dict(self.env, REQUIRED_CHANNELS=json.dumps([value]))
                with patch.dict(os.environ, env, clear=True):
                    with self.assertRaises(ConfigurationError) as caught:
                        Settings.load()
                self.assertIn('id, title and url', str(caught.exception))
                self.assertNotIn('synthetic', str(caught.exception))

    def test_cli_reports_all_missing_fields_when_no_dotenv_exists(self):
        env = {key: value for key, value in os.environ.items() if key not in self.env}
        env['PYTHONPATH'] = str(Path(__file__).resolve().parents[1])
        with tempfile.TemporaryDirectory() as directory:
            result = subprocess.run([sys.executable, '-m', 'cinespice_bot', 'run'],
                                    cwd=directory, env=env, capture_output=True, text=True)
            self.assertFalse(Path(directory, 'state').exists())
        self.assertEqual(result.returncode, 1)
        self.assertIn('Bot configuration error:', result.stderr)
        self.assertIn('.env', result.stderr)
        for name in self.env:
            self.assertIn(name, result.stderr)
        self.assertNotIn('synthetic-secret', result.stdout + result.stderr)
        self.assertNotIn('Traceback', result.stderr)

    def test_dotenv_loads_quoted_channels_and_windows_paths(self):
        self.write_env('REQUIRED_CHANNELS=\'[{"id":-1002,"title":"Community members","url":"https://t.me/community"}]\'\n'
                       'SIGNING_KEY="C:\\Bot Files\\state\\signing-key.pem"\n'
                       'ACCESS_TTL_SECONDS=120\n')
        with patch.dict(os.environ, {}, clear=True):
            settings = Settings.load()
            self.assertNotIn('BOT_TOKEN', os.environ)
        self.assertEqual(settings.token, self.env['BOT_TOKEN'])
        self.assertEqual(settings.channels[0]['title'], 'Community members')
        self.assertEqual(str(settings.key_path), 'C:\\Bot Files\\state\\signing-key.pem')
        self.assertEqual(settings.ttl, 120)

    def test_terminal_settings_take_precedence_and_literals_are_not_executed(self):
        self.write_env('BOT_TOKEN=\'123456:${UNCHANGED}$(touch unexpected-file)\'\n')
        with patch.dict(os.environ, {}, clear=True):
            self.assertEqual(Settings.load().token, '123456:${UNCHANGED}$(touch unexpected-file)')
        self.assertFalse(Path('unexpected-file').exists())
        with patch.dict(os.environ, {'BOT_TOKEN': '123456:terminal-secret'}, clear=True):
            self.assertEqual(Settings.load().token, '123456:terminal-secret')

    def test_windows_bom_and_crlf_are_supported(self):
        content = '# Local settings\r\n' + '\r\n'.join(f'export {key}=\'{value}\'' for key, value in self.env.items())
        Path('.env').write_bytes(content.encode('utf-8-sig'))
        with patch.dict(os.environ, {}, clear=True):
            self.assertEqual(Settings.load().username, self.env['BOT_USERNAME'])

    def test_parent_dotenv_is_not_searched(self):
        self.write_env()
        Path('child').mkdir()
        os.chdir('child')
        with patch.dict(os.environ, {}, clear=True), self.assertRaises(ConfigurationError):
            Settings.load()

    def test_invalid_encoding_and_empty_file_setting_have_safe_errors(self):
        Path('.env').write_bytes(b'BOT_TOKEN=\xffsynthetic-secret')
        with patch.dict(os.environ, {}, clear=True):
            with self.assertRaises(ConfigurationError) as caught:
                Settings.load()
        self.assertIn('UTF-8', str(caught.exception))
        self.assertNotIn('synthetic-secret', str(caught.exception))
        self.write_env('BOT_TOKEN\n')
        with patch.dict(os.environ, {}, clear=True):
            with self.assertRaises(ConfigurationError) as caught:
                Settings.load()
        self.assertIn('BOT_TOKEN', str(caught.exception))

    def test_run_uses_existing_key_and_database_from_local_file(self):
        self.write_env()
        key = Path('state/signing-key.pem')
        generate_key(key)
        original_key = key.read_bytes()
        store = Store(Path('state/bot.sqlite3'))
        store.start(7)
        store.close()
        public = Path('access-config.local.json')
        public.write_text('{"existing":"public export"}')
        with patch.dict(os.environ, {}, clear=True), patch.object(sys, 'argv', ['cinespice_bot', 'run']):
            with patch('cinespice_bot.__main__.build_application') as builder:
                main()
                settings, _, signer = builder.call_args.args
                self.assertEqual(settings.token, self.env['BOT_TOKEN'])
                self.assertEqual(signer.public_key(), Signer(key).public_key())
                builder.return_value.run_polling.assert_called_once()
        self.assertEqual(key.read_bytes(), original_key)
        self.assertEqual(public.read_text(), '{"existing":"public export"}')
        reopened = Store(Path('state/bot.sqlite3'))
        try:
            self.assertTrue(reopened.started(7))
        finally:
            reopened.close()

    def test_cli_exports_from_dotenv_using_existing_signing_key(self):
        self.write_env()
        key = Path('state/signing-key.pem')
        generate_key(key)
        original_key = key.read_bytes()
        names = {*self.env, 'REQUIRED_CHANNELS', 'SIGNING_KEY', 'DATABASE', 'ACCESS_TTL_SECONDS'}
        env = {key: value for key, value in os.environ.items() if key not in names}
        env['PYTHONPATH'] = str(Path(__file__).resolve().parents[1])
        result = subprocess.run([sys.executable, '-m', 'cinespice_bot', 'export-config', '--out', 'public.json'],
                                env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        exported = json.loads(Path('public.json').read_text())
        self.assertEqual(exported['publicKey'], Signer(key).public_key())
        self.assertEqual(exported['botUsername'], self.env['BOT_USERNAME'])
        self.assertNotIn('synthetic-secret', Path('public.json').read_text() + result.stdout + result.stderr)
        self.assertEqual(key.read_bytes(), original_key)

    def test_cli_reports_missing_signing_key_without_creating_state_or_leaking_values(self):
        self.write_env('SIGNING_KEY=private-synthetic-path/missing.pem\n')
        names = {*self.env, 'REQUIRED_CHANNELS', 'SIGNING_KEY', 'DATABASE', 'ACCESS_TTL_SECONDS'}
        env = {key: value for key, value in os.environ.items() if key not in names}
        env['PYTHONPATH'] = str(Path(__file__).resolve().parents[1])
        for command in (['run'], ['export-config', '--out', 'public.json']):
            with self.subTest(command=command):
                result = subprocess.run([sys.executable, '-m', 'cinespice_bot', *command],
                                        env=env, capture_output=True, text=True)
                self.assertEqual(result.returncode, 1)
                self.assertIn('Signing key file not found', result.stderr)
                self.assertIn('SIGNING_KEY', result.stderr)
                self.assertIn('Restore the original key', result.stderr)
                self.assertNotIn('private-synthetic-path', result.stdout + result.stderr)
                self.assertNotIn('synthetic-secret', result.stdout + result.stderr)
                self.assertNotIn('Traceback', result.stderr)
                self.assertFalse(Path('state').exists())
                self.assertFalse(Path('private-synthetic-path').exists())
                self.assertFalse(Path('public.json').exists())

    def test_optional_chat_group_url_preserves_existing_configuration(self):
        with patch.dict(os.environ,self.env,clear=True):
            self.assertEqual(Settings.load().chat_group_url,'')
        with patch.dict(os.environ,{**self.env,'CHAT_GROUP_URL':'https://t.me/support_chat'},clear=True):
            self.assertEqual(Settings.load().chat_group_url,'https://t.me/support_chat')
        with patch.dict(os.environ,{**self.env,'CHAT_GROUP_URL':'http://example.com'},clear=True),self.assertRaises(ValueError):
            Settings.load()


if __name__ == '__main__':
    unittest.main()
