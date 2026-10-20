import math
import os
import pathlib
import shutil
import struct
import subprocess
import tempfile
import wave

ROOT = pathlib.Path(tempfile.mkdtemp(prefix='transcribe-audio-test-'))
FFMPEG = os.environ.get('TRANSCRIBE_FFMPEG') or shutil.which('ffmpeg')
FFPROBE = os.environ.get('TRANSCRIBE_FFPROBE') or shutil.which('ffprobe')
if not FFMPEG or not FFPROBE:
    raise SystemExit('Set TRANSCRIBE_FFMPEG/TRANSCRIBE_FFPROBE or add both tools to PATH.')
MODULE = pathlib.Path(__file__).resolve().parents[2] / 'transcribe_audio.psm1'


def ffmpeg(*args):
    subprocess.run([FFMPEG, '-hide_banner', '-loglevel', 'error', '-y', *args], check=True)


def prepare(source):
    output = source.with_name(source.stem + '-processed.wav')
    command = (f"Import-Module '{MODULE}' -Force; "
               f"Convert-TranscriptAudio -InputPath '{source}' -OutputPath '{output}' "
               f"-FfmpegPath '{FFMPEG}' -FfprobePath '{FFPROBE}' | Out-Null")
    subprocess.run(['pwsh', '-NoProfile', '-Command', command], check=True)
    with wave.open(str(output)) as wav:
        assert wav.getnchannels() == 1 and wav.getframerate() == 16000
        samples = struct.unpack('<' + 'h' * wav.getnframes(), wav.readframes(wav.getnframes()))
    return samples


def amplitude(samples, frequency):
    values = samples[2000:12000]
    return abs(sum(value * complex(math.cos(2 * math.pi * frequency * i / 16000),
                                   math.sin(2 * math.pi * frequency * i / 16000))
                   for i, value in enumerate(values))) / len(values)


for name, expression, channels in [
    ('mono.wav', '0.2*sin(2*PI*440*t)', 1),
    ('stereo.wav', '0.2*sin(2*PI*440*t)|0.2*sin(2*PI*880*t)', 2),
    ('stereo.mp3', '0.2*sin(2*PI*440*t)|0.2*sin(2*PI*880*t)', 2),
    ('right-only.wav', '0|0.2*sin(2*PI*880*t)', 2),
    ('surround.wav', '0.1*sin(2*PI*440*t)|0.1*sin(2*PI*880*t)|0|0|0|0', 6),
]:
    source = ROOT / name
    ffmpeg('-f', 'lavfi', '-i', f'aevalsrc={expression}:s=48000:d=1', '-ac', str(channels), str(source))
    samples = prepare(source)
    assert abs(len(samples) / 16000 - 1) < 0.02, name
    if name == 'right-only.wav':
        assert max(abs(x) for x in samples) == 0, 'Right channel leaked into mono'
    elif channels <= 2:
        assert amplitude(samples, 440) > 1000, name
        assert amplitude(samples, 880) < amplitude(samples, 440) * 0.03, name
    else:
        assert amplitude(samples, 440) > 100 and amplitude(samples, 880) > 100
    print('PASS', name)

video = ROOT / 'delayed.mp4'
ffmpeg('-f', 'lavfi', '-i', 'color=black:s=32x32:r=10:d=2', '-itsoffset', '0.6',
       '-i', str(ROOT / 'stereo.wav'), '-map', '0:v', '-map', '1:a',
       '-c:v', 'mpeg4', '-c:a', 'aac', str(video))
samples = prepare(video)
assert max(abs(x) for x in samples[:8000]) <= 2, 'Leading audio offset lost'
assert 1.55 <= len(samples) / 16000 <= 1.70, 'Video timeline changed'
assert amplitude(samples[9600:], 880) < amplitude(samples[9600:], 440) * 0.03
print('PASS stereo video with delayed audio; media timeline preserved')
print('Audio checks passed:', ROOT)
