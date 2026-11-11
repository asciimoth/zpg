"""Prepare disposable local workloads, then record the public CLI commands."""
import json
import os
from pathlib import Path
import runpy
import shlex
import shutil
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parent.parent
helpers = runpy.run_path(str(ROOT / 'scripts' / 'guess-demo.py'))
data_file = helpers['data_file']
slow_http = helpers['slow_http']


def main():
    with tempfile.TemporaryDirectory(prefix='zpg-recording-') as temporary:
        directory = Path(temporary)
        for name in ('bin', 'input', 'copy', 'source'):
            (directory / name).mkdir()
        for index in range(1, 4):
            data_file(directory / 'input' / f'part-{index}.bin', mib=index + 3)
        data_file(directory / 'source' / 'data.bin')
        data_file(directory / 'download.bin')
        subprocess.run([
            'ffmpeg', '-hide_banner', '-loglevel', 'error', '-nostdin',
            '-f', 'lavfi', '-i', 'testsrc2=size=640x360:rate=30',
            '-t', '10', '-c:v', 'mpeg4', '-q:v', '5', 'input.avi',
        ], cwd=directory, check=True)

        # Slow only this recording's copies. Keep instrumentation out of the tape.
        cp = shlex.quote(shutil.which('cp'))
        wrapper = directory / 'bin' / 'cp'
        wrapper.write_text(
            '#!/bin/sh\n'
            'exec strace -f -qq -o /dev/null -e trace=read,copy_file_range '
            '-e inject=read:delay_enter=300ms '
            '-e inject=copy_file_range:error=ENOSYS '
            f'{cp} --reflink=never --sparse=never "$@"\n'
        )
        wrapper.chmod(0o755)

        env = {key: value for key, value in os.environ.items() if not key.startswith('GIT_')}
        env.update(GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL=os.devnull,
                   GIT_TERMINAL_PROMPT='0', GIT_ATTR_NOSYSTEM='1',
                   GIT_CONFIG_COUNT='4', GIT_CONFIG_KEY_0='init.templateDir',
                   GIT_CONFIG_VALUE_0='', GIT_CONFIG_KEY_1='core.hooksPath',
                   GIT_CONFIG_VALUE_1=os.devnull, GIT_CONFIG_KEY_2='http.proxy',
                   GIT_CONFIG_VALUE_2='', GIT_CONFIG_KEY_3='commit.gpgsign',
                   GIT_CONFIG_VALUE_3='false')
        repo = directory / 'repository'
        repo.mkdir()
        data_file(repo / 'data.bin', random=True)
        for args in [('init', '-q'), ('add', 'data.bin'),
                     ('-c', 'user.name=Example', '-c', 'user.email=example@example.invalid',
                      'commit', '-qm', 'Initial commit'),
                     ('repack', '-ad'), ('update-server-info',)]:
            subprocess.run(['git', *args], cwd=repo, env=env, check=True)

        with slow_http(directory) as url:
            tasks = {'tasks': [
                {'name': 'cp recursive', 'guess': True,
                 'command': ['cp', '-rv', 'source/', 'copied/']},
                {'name': 'curl download', 'guess': True,
                 'command': ['curl', '--fail', '--show-error', '--noproxy', '*',
                             url + '/download.bin', '-o', 'received.bin']},
                {'name': 'ffmpeg transcode', 'guess': True,
                 'command': ['ffmpeg', '-hide_banner', '-nostdin', '-re',
                             '-i', 'input.avi', '-c:v', 'mpeg4', '-q:v', '3', 'output.avi']},
            ]}
            (directory / 'tasks.json').write_text(json.dumps(tasks, indent=2) + '\n')
            env.update(PATH=f'{directory / "bin"}:{ROOT / "zig-out/bin"}:{env["PATH"]}',
                       ZPG_RECORDING_DIR=str(directory), REPO_URL=url + '/repository/.git/')
            subprocess.run(['vhs', 'demo.tape'], cwd=ROOT, env=env, check=True)


if __name__ == '__main__':
    main()
