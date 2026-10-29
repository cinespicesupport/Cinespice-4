import copy
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[2]
spec=importlib.util.spec_from_file_location('configure_access',ROOT/'scripts/configure-access.py')
module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)

class PublicConfigTests(unittest.TestCase):
    def test_exported_shape_and_private_material_rejection(self):
        valid=json.loads((ROOT/'access-config.example.json').read_text())
        self.assertEqual(module.validate(valid),valid)
        for change in [{'BOT_TOKEN':'synthetic-secret'},{'publicKey':'not-a-public-key'},{'contactURL':'http://t.me/contact'},{'botUserID':'-1'},{'botUsername':'some_user'},{'channels':[{'title':'Community','url':'https://t.me@evil.example/channel'}]}]:
            data=copy.deepcopy(valid);data.update(change)
            with self.assertRaises((ValueError,TypeError)):module.validate(data)
        import base64
        data=copy.deepcopy(valid);key=bytearray(base64.b64decode(data['publicKey']));key[27:]=bytes(64);data['publicKey']=base64.b64encode(key).decode()
        with self.assertRaises(ValueError):module.validate(data)
    def test_cli_generation_and_invalid_input_preserves_previous_file(self):
        valid=(ROOT/'access-config.example.json').read_text()
        with tempfile.TemporaryDirectory() as directory:
            target=Path(directory)/'access.json';env=dict(os.environ,CINESPICE_ACCESS_CONFIG_JSON=valid)
            command=[sys.executable,str(ROOT/'scripts/configure-access.py'),'--out',str(target)]
            result=subprocess.run(command,env=env,capture_output=True,text=True);self.assertEqual(result.returncode,0)
            previous=target.read_bytes();env['CINESPICE_ACCESS_CONFIG_JSON']='{"BOT_TOKEN":"synthetic-secret"}'
            result=subprocess.run(command,env=env,capture_output=True,text=True);self.assertNotEqual(result.returncode,0)
            self.assertNotIn('synthetic-secret',result.stdout+result.stderr);self.assertEqual(target.read_bytes(),previous)
    def test_operator_keygen_and_export_commands(self):
        with tempfile.TemporaryDirectory() as directory:
            base=Path(directory); key=base/'key.pem'; public=base/'public.json'
            env=dict(os.environ,PYTHONPATH=str(ROOT/'licensing-bot'),BOT_TOKEN='123456:synthetic-token',BOT_USERNAME='synthetic_bot',BOT_USER_ID='123456',PAID_GROUP_ID='-1001',ADMIN_IDS='42',CONTACT_URL='https://t.me/contact',REQUIRED_CHANNELS='[]',SIGNING_KEY=str(key))
            command=[sys.executable,'-m','cinespice_bot']
            created=subprocess.run(command+['keygen','--out',str(key)],cwd=ROOT/'licensing-bot',env=env,capture_output=True,text=True)
            self.assertEqual(created.returncode,0)
            exported=subprocess.run(command+['export-config','--out',str(public)],cwd=ROOT/'licensing-bot',env=env,capture_output=True,text=True)
            self.assertEqual(exported.returncode,0)
            config=json.loads(public.read_text());self.assertEqual(module.validate(config),config)
            self.assertNotIn('synthetic-token',public.read_text());self.assertNotIn('PRIVATE KEY',public.read_text())
            self.assertEqual(key.stat().st_mode & 0o777,0o600)
            for operation,path in [('keygen',key),('export-config',public)]:
                result=subprocess.run(command+[operation,'--out',str(path)],cwd=ROOT/'licensing-bot',env=env,capture_output=True,text=True)
                self.assertNotEqual(result.returncode,0)
