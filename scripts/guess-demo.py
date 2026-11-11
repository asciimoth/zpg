"""Run visible, local-only --guess demos with disposable input and output."""
import contextlib
import functools
import http.server
import os
from pathlib import Path
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import threading


ROOT = Path(__file__).resolve().parent.parent
MIB = 1024 * 1024
TOOLS = {
    'cp': ('cp', 'strace'),
    'cp-parallel': ('cp', 'strace'),
    'tar': ('tar', 'strace'),
    'gzip': ('gzip', 'strace'),
    'rsync': ('rsync',),
    'curl': ('curl',),
    'git': ('git',),
    'ffmpeg': ('ffmpeg',),
    'tasks': ('cp', 'strace', 'curl', 'ffmpeg'),
}


def run(command, *, cwd, env=None, stdout=None):
    # Keep the supervisor separate from the demo driver's terminal signals.
    # On interruption, let zpg stop its whole child process group before the
    # temporary directory or HTTP server is removed.
    with subprocess.Popen(command, cwd=cwd, env=env, stdout=stdout,
                          start_new_session=True) as process:
        try:
            code = process.wait()
        except BaseException:
            process.send_signal(signal.SIGINT)
            try:
                process.wait(timeout=4)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
            raise
        if code:
            raise subprocess.CalledProcessError(code, command)


def data_file(path, mib=4, random=False):
    block = os.urandom(MIB) if random else bytes(range(256)) * 4096
    with path.open('wb') as output:
        for _ in range(mib):
            output.write(block)


def slow_reads(command, delay_ms, *, copy=False):
    # This is demo-only instrumentation. zpg itself neither traces commands
    # nor changes their arguments. cp's fast-copy paths are disabled here so
    # a small file still takes several seconds to read.
    trace = ['strace', '-f', '-qq', '-o', os.devnull,
             '-e', 'trace=read,copy_file_range',
             '-e', f'inject=read:delay_enter={delay_ms}ms']
    if copy:
        trace += ['-e', 'inject=copy_file_range:error=ENOSYS']
    return [*trace, *command]


def copy_command(source, target):
    return slow_reads(['cp', '-v', '--reflink=never', '--sparse=never',
                       str(source), str(target)], 350, copy=True)


def parallel_copies():
    # This helper runs *inside* zpg. Keep all three copies in its process group
    # so the generic sampler sees them and Ctrl+C reaches every worker.
    with contextlib.ExitStack() as stack:
        workers = [stack.enter_context(subprocess.Popen(copy_command(
            f'input-{index}.bin', f'copy-{index}.bin'))) for index in range(1, 4)]
        return max(worker.wait() for worker in workers)


@contextlib.contextmanager
def slow_http(directory):
    stop = threading.Event()

    class Handler(http.server.SimpleHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def copyfile(self, source, outputfile):
            # 64 KiB per 125 ms: about 512 KiB/s, including cached local data.
            try:
                while not stop.is_set():
                    block = source.read(65536)
                    if not block:
                        break
                    outputfile.write(block)
                    outputfile.flush()
                    if stop.wait(.125):
                        break
            except (BrokenPipeError, ConnectionResetError):
                pass

    handler = functools.partial(Handler, directory=str(directory))
    with http.server.ThreadingHTTPServer(('127.0.0.1', 0), handler) as server:
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            yield f'http://127.0.0.1:{server.server_port}'
        finally:
            stop.set()
            server.shutdown()
            thread.join()


def demo(tool, directory):
    zpg = str(ROOT / 'zig-out' / 'bin' / 'zpg')

    def show(command, *, env=None, stdout=None):
        command = [zpg, '--guess', '--name', f'{tool} demo', *command]
        print('+ ' + shlex.join(command), flush=True)
        run(command, cwd=directory, env=env, stdout=stdout)

    print('Preparing temporary demo data. Ctrl+C stops the demo and cleans up.', flush=True)
    if tool in ('cp', 'cp-parallel'):
        if tool == 'cp':
            data_file(directory / 'input.bin')
            print('Watch the input-file percentage (about 8 seconds).', flush=True)
            show(copy_command('input.bin', 'copy.bin'))
        else:
            for index in range(1, 4):
                data_file(directory / f'input-{index}.bin', mib=index + 3)
            print('Watch three file rows advance independently (about 12 seconds).', flush=True)
            show([sys.executable, str(Path(__file__).resolve()), '--parallel'])
    elif tool == 'tar':
        data_file(directory / 'input.bin')
        run(['tar', '-cf', 'input.tar', 'input.bin'], cwd=directory)
        (directory / 'extracted').mkdir()
        print('Watch the archive read position (about 9 seconds).', flush=True)
        show(slow_reads(['tar', '-xf', 'input.tar', '-C', 'extracted'], 20))
    elif tool == 'gzip':
        data_file(directory / 'input.bin')
        print('Watch input reads while compressed output goes to a file (about 8 seconds).', flush=True)
        with (directory / 'input.bin.gz').open('wb') as output:
            show(slow_reads(['gzip', '-c', 'input.bin'], 60), stdout=output)
    elif tool == 'rsync':
        (directory / 'source').mkdir()
        for index in range(1, 5):
            data_file(directory / 'source' / f'part-{index}.bin', mib=1)
        print('Watch I/O activity; rsync may read without advancing file offsets (about 8 seconds).', flush=True)
        show(['rsync', '-a', '--bwlimit=512', 'source/', 'destination/'])
    elif tool == 'curl':
        data_file(directory / 'download.bin')
        print('Watch TCP receive counts and rates from a local server (about 8 seconds).', flush=True)
        with slow_http(directory) as url:
            show(['curl', '--fail', '--silent', '--show-error', '--noproxy', '*',
                  f'{url}/download.bin', '--output', 'received.bin'])
    elif tool == 'git':
        # Ignore user Git settings, hooks, signing, and repository overrides.
        # Every Git write stays inside this disposable repository.
        env = {key: value for key, value in os.environ.items() if not key.startswith('GIT_')}
        env.update(GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL=os.devnull,
                   GIT_TERMINAL_PROMPT='0', GIT_ATTR_NOSYSTEM='1')
        git = ['git', '-c', 'init.templateDir=', '-c', 'core.hooksPath=' + os.devnull,
               '-c', 'http.proxy=', '-c', 'user.name=zpg demo',
               '-c', 'user.email=demo@example.invalid', '-c', 'commit.gpgsign=false']
        run([*git, 'init', '-q', 'source'], cwd=directory, env=env)
        repo = directory / 'source'
        data_file(repo / 'data.bin', random=True)
        for args in [('add', 'data.bin'), ('commit', '-qm', 'Demo data'),
                     ('repack', '-ad'), ('update-server-info',)]:
            run([*git, *args], cwd=repo, env=env)
        print('Watch TCP activity while Git clones a local repository (about 9 seconds).', flush=True)
        with slow_http(repo / '.git') as url:
            show([*git, 'clone', '--quiet', url + '/', 'cloned'], env=env)
    elif tool in ('ffmpeg', 'tasks'):
        common = ['ffmpeg', '-hide_banner', '-loglevel', 'error', '-nostdin', '-nostats']
        run([*common, '-f', 'lavfi', '-i', 'testsrc2=size=640x360:rate=30',
             '-t', '10', '-c:v', 'mpeg4', '-q:v', '5', 'input.avi'], cwd=directory)
        if tool == 'ffmpeg':
            print('Watch input reads and CPU activity at playback speed (about 10 seconds).', flush=True)
            show([*common, '-re', '-i', 'input.avi', '-c:v', 'mpeg4', '-q:v', '3', 'output.avi'])
        else:
            source = directory / 'source'
            (source / 'nested').mkdir(parents=True)
            data_file(source / 'first.bin', mib=2)
            data_file(source / 'nested' / 'second.bin', mib=2)
            data_file(directory / 'download.bin')
            print('Watch three tasks with verbose output (about 10 seconds).', flush=True)
            with slow_http(directory) as url:
                command = [zpg, '--tasks', str(ROOT / 'example.json'), str(directory), url]
                print('+ ' + shlex.join(command), flush=True)
                run(command, cwd=directory)
            for relative in ('first.bin', 'nested/second.bin'):
                assert (source / relative).read_bytes() == (directory / 'copied' / relative).read_bytes()
            assert (directory / 'download.bin').read_bytes() == (directory / 'received.bin').read_bytes()
            assert (directory / 'output.avi').stat().st_size > 0
    print('Demo complete. Temporary files removed on exit.', flush=True)


def main():
    if sys.argv[1:] == ['--parallel']:
        try:
            return parallel_copies()
        except KeyboardInterrupt:
            return 130
    if len(sys.argv) != 2 or sys.argv[1] not in TOOLS:
        print('Usage: python3 scripts/guess-demo.py {' + ','.join(TOOLS) + '}', file=sys.stderr)
        return 2
    if not sys.platform.startswith('linux'):
        print('These --guess demos require Linux process metadata.', file=sys.stderr)
        return 2
    tool = sys.argv[1]
    missing = [name for name in TOOLS[tool] if shutil.which(name) is None]
    if missing:
        print('Missing demo tools: ' + ', '.join(missing) + '. Run nix develop first.', file=sys.stderr)
        return 2
    if not (ROOT / 'zig-out' / 'bin' / 'zpg').is_file():
        print('Build zpg first with zig build, or use just demo-' + tool, file=sys.stderr)
        return 2
    # A termination from a shell or test runner must also run cleanup.
    def interrupt(signum, frame):
        raise KeyboardInterrupt
    signal.signal(signal.SIGTERM, interrupt)
    try:
        with tempfile.TemporaryDirectory(prefix='zpg-guess-demo-') as path:
            demo(tool, Path(path))
    except KeyboardInterrupt:
        print('\nDemo interrupted; temporary files removed.', file=sys.stderr)
        return 130
    except subprocess.CalledProcessError as error:
        print(f'Demo command failed (exit {error.returncode}).', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
