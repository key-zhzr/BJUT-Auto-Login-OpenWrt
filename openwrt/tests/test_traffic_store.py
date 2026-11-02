"""Real gzip quotas and long retention, without a router or billing service."""
import gzip
import hashlib
import json
from pathlib import Path
import random
import shutil
import subprocess
import tempfile
import unittest


SOURCE = Path(__file__).resolve().parents[1] / 'bjut-autologin/src/bjut-traffic-store.c'


class TrafficStoreTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build = Path(tempfile.mkdtemp(prefix='bjut-store-build-'))
        cls.binary = cls.build / 'store'
        subprocess.run(['cc', '-std=c99', '-O2', '-Wall', '-Wextra', '-Werror', SOURCE, '-o', cls.binary, '-lz'], check=True)

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.build)

    def setUp(self):
        self.temp = Path(tempfile.mkdtemp(prefix='bjut-store-case-'))
        self.state = self.temp / 'state'; self.state.mkdir()
        self.flash = self.temp / 'flash'; self.flash.mkdir()
        self.call('init', self.state, self.flash / 'usage-samples.tsv', self.flash / 'usage-curves.tsv')
        self.now = 1793577600

    def tearDown(self):
        shutil.rmtree(self.temp)

    def call(self, *args):
        return subprocess.check_output([self.binary, *map(str, args)], text=True)

    def current(self):
        return self.state / (self.state / 'traffic-store-current').read_text().strip()

    @staticmethod
    def row(at, amount='1.234', channel=0, resolution=60, start=None, end=None):
        return f'{resolution}\t{at}\t{channel:016x}\t{channel:016x}\tinterface:lan{channel+3}\tlan{channel+3}\t1\t{amount}\t60\t{at-59 if start is None else start}\t{at+1 if end is None else end}\n'

    def compact(self, limit=4*1048576, minute_hours=7200):
        output = Path(tempfile.mkdtemp(prefix='checkpoint-', dir=self.temp))
        info = json.loads(self.call('compact', self.state, output, self.now, minute_hours, 90, 366, limit, 0))
        size = sum((output / name).stat().st_size for name in ['usage-curves.tsv.dict.gz', 'usage-samples.tsv.dict.gz', 'usage-switches.tsv', 'usage-curves.tsv.index'])
        self.assertEqual(info['flashBytes'], size)
        self.assertLessEqual(size, limit)
        return output, info

    def test_more_than_old_row_cap_keeps_new_samples_and_rollups_share_capacity(self):
        rows = 18000
        journal = self.current() / 'usage-curves.tsv'
        with journal.open('w') as f:
            for i in range(rows):
                f.write(self.row(self.now-(rows-1-i)*60))
        output, info = self.compact()
        self.assertEqual(info['retainedRows'], rows)
        self.assertEqual(info['trimmedRows'], 0)
        self.call('commit', self.state, output)
        with (self.current() / 'usage-curves.tsv').open('a') as f:
            f.write(self.row(self.now+60, '2.345'))
        data = self.call('stream', 'curves', self.state).splitlines()
        self.assertEqual(len(data), rows+1)
        self.assertEqual(int(data[-1].split('\t')[1]), self.now+60)

    def test_full_7200_hours_survive_flash_checkpoint_and_restart(self):
        # Three upstreams, every minute for 300 days. The expanded history is
        # over 100 MB; neither it nor RAM verification is a 4 MB quota item.
        minutes = 7200*60
        oldest = self.now-(minutes-1)*60
        journal = self.current() / 'usage-curves.tsv'
        with journal.open('w') as f:
            for i in range(minutes):
                for channel in range(3):
                    f.write(self.row(oldest+i*60, f'{(i*17+channel*37)%113}.{i%1000:03}', channel))
            f.write(self.row(self.now-7200*3600-60, channel=0))
        self.assertGreater(journal.stat().st_size, 100*1048576)
        output, info = self.compact()
        self.assertEqual(info['retainedRows'], minutes*3, info)
        self.assertEqual(info['trimmedRows'], 0, info)
        self.assertEqual(gzip.open(output/'usage-curves.tsv.dict.gz', 'rt').readline(), 'BJUT-TRAFFIC\t2\tcurves\n')
        for name in ['usage-curves.tsv.dict.gz', 'usage-samples.tsv.dict.gz', 'usage-switches.tsv', 'usage-curves.tsv.index']:
            shutil.copyfile(output/name, self.flash/name)
        shutil.rmtree(self.state); self.state.mkdir()
        self.call('init', self.state, self.flash/'usage-samples.tsv', self.flash/'usage-curves.tsv')
        self.assertEqual((self.current()/'usage-curves.tsv').stat().st_size, 0)
        recent = self.call('stream', 'curves', self.state, self.now-3600, self.now)
        self.assertLess(len(recent.splitlines()), 3*1441)
        self.assertEqual(int(recent.splitlines()[-1].split('\t')[1]), self.now)
        count, first, last = 0, None, None
        process = subprocess.Popen([self.binary, 'stream', 'curves', self.state], stdout=subprocess.PIPE, text=True)
        for line in process.stdout:
            at = int(line.split('\t')[1]); first = at if first is None else first; last = at; count += 1
        process.stdout.close(); self.assertEqual(process.wait(), 0)
        self.assertEqual((count, first, last), (minutes*3, oldest, self.now))

    def test_measured_shared_quota_removes_oldest_timestamps_and_keeps_latest(self):
        randomizer = random.Random(42)
        journal = self.current()/'usage-curves.tsv'
        with journal.open('w') as f:
            for i in range(30000):
                f.write(self.row(self.now-(29999-i)*60, str(randomizer.randrange(100000)/1000), i%3))
            f.write(self.row(self.now, '8.000', 0, 3600))
        switches = self.state/'traffic-switches.tsv'
        switches.write_text(f'{self.now}\tinterface:lan3\tlan3\told\tnew\tchanged\n')
        output, info = self.compact(limit=32768)
        self.assertGreater(info['trimmedRows'], 0)
        self.assertGreater((output/'usage-switches.tsv').stat().st_size, 0)
        self.call('commit', self.state, output)
        result = self.call('stream', 'curves', self.state).splitlines()
        timestamps = [int(row.split('\t')[1]) for row in result]
        self.assertEqual(max(timestamps), self.now)
        self.assertGreater(min(timestamps), self.now-29999*60)
        self.assertTrue(any(row.startswith('3600\t') for row in result))

    def test_journal_cutover_is_atomic_and_no_records_are_counted_twice(self):
        journal = self.current()/'usage-curves.tsv'
        journal.write_text(self.row(self.now-60, '1.111'))
        output, _ = self.compact(); self.call('commit', self.state, output)
        (self.current()/'usage-curves.tsv').write_text(self.row(self.now, '2.222'))
        before = self.call('stream', 'curves', self.state)
        output, _ = self.compact(); self.call('commit', self.state, output)
        self.assertEqual(self.call('stream', 'curves', self.state), before)
        self.assertEqual((self.current()/'usage-curves.tsv').stat().st_size, 0)
        self.call('commit', self.state, output)
        self.assertEqual(self.call('stream', 'curves', self.state), before)

    def test_indexed_queries_keep_the_first_partial_bucket_and_hot_journal(self):
        journal = self.current()/'usage-curves.tsv'
        # Each day is an independently decodable gzip member.
        first = self.now-10*86400
        journal.write_text(''.join(self.row(first+i*60) for i in range(10*1440+1)))
        output, _ = self.compact(); self.call('commit', self.state, output)
        (self.current()/'usage-curves.tsv').write_text(self.row(self.now+60))
        result = self.call('stream', 'curves', self.state, self.now-60, self.now+60)
        times = [int(row.split('\t')[1]) for row in result.splitlines()]
        self.assertIn(self.now-60, times)
        self.assertEqual(times[-1], self.now+60)
        self.assertLessEqual(len(times), 1442)

    def test_v1_migration_and_v2_interval_offsets_are_lossless(self):
        rows = [self.row(self.now-60, start=self.now-121, end=self.now-59),
                self.row(self.now, start=self.now-59, end=self.now+1),
                self.row(self.now-3600, resolution=3600, start=0, end=0)]
        (self.current()/'usage-curves.tsv').write_text(''.join(rows))
        output, _ = self.compact(); decoded = self.temp/'decoded.tsv'
        self.call('unpack', 'curves', output/'usage-curves.tsv.dict.gz', decoded, 1048576)
        self.assertEqual(sorted(decoded.read_text().splitlines()), sorted(''.join(rows).splitlines()))
        self.call('commit', self.state, output)
        self.assertEqual(sorted(self.call('stream', 'curves', self.state).splitlines()), sorted(decoded.read_text().splitlines()))

    def test_corruption_does_not_publish_a_partial_restore_or_destroy_journal(self):
        (self.current()/'usage-curves.tsv').write_text(self.row(self.now))
        output, _ = self.compact(); self.call('commit', self.state, output)
        packed = self.current()/'usage-curves.tsv.dict.gz'
        packed.write_bytes(packed.read_bytes()[:-5])
        journal = self.current()/'usage-curves.tsv'; journal.write_text(self.row(self.now+60))
        before = hashlib.sha256(journal.read_bytes()).digest()
        bad_output = self.temp/'bad'; bad_output.mkdir()
        result = subprocess.run([self.binary, 'compact', self.state, bad_output, str(self.now+60), '7200', '90', '366', '4194304', '0'], capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(hashlib.sha256(journal.read_bytes()).digest(), before)
        target = self.temp/'invalid.tsv'
        result = subprocess.run([self.binary, 'unpack', 'curves', packed, target, '4194304'], capture_output=True)
        self.assertNotEqual(result.returncode, 0); self.assertFalse(target.exists())
        corrupt = packed.read_bytes()
        shutil.rmtree(self.state); self.state.mkdir()
        (self.flash/'usage-curves.tsv.dict.gz').write_bytes(corrupt)
        result = subprocess.run([self.binary, 'init', self.state, self.flash/'usage-samples.tsv', self.flash/'usage-curves.tsv'], capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.state/'traffic-store-current').exists())
        self.assertEqual((self.flash/'usage-curves.tsv.dict.gz').read_bytes(), corrupt)


if __name__ == '__main__':
    unittest.main()
