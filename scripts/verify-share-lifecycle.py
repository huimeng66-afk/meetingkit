#!/usr/bin/env python3
"""Offline source invariants + SDP reference fixtures; NOT a Swift/iOS runtime test."""
from pathlib import Path
import unittest
ROOT = Path(__file__).resolve().parents[1]
def read(p): return (ROOT / p).read_text()
def sections(sdp):
    result, current, direction, session = [], None, 'sendrecv', True
    for line in sdp.splitlines():
        if line.startswith('m='):
            if current is not None: result.append(current)
            session = False
            f = line.split()
            current = dict(mid='', screen=False, rejected=len(f)<2 or f[1].split('/')[0]=='0', direction=direction) if f[0]=='m=video' else None
        elif line in ('a=sendrecv','a=sendonly','a=recvonly','a=inactive'):
            if session: direction = line[2:]
            elif current is not None: current['direction'] = line[2:]
        elif current is not None:
            if line.startswith('a=mid:'): current['mid'] = line[6:]
            if line.startswith('a=msid:screen-'): current['screen'] = True
    if current is not None: result.append(current)
    return result
def allowed(sdp, mid, sending):
    return bool(mid) and any(x['mid']==mid and not x['rejected'] and (x['screen'] if sending else True) and x['direction'] in (('sendonly','sendrecv') if sending else ('recvonly','sendrecv')) for x in sections(sdp))
class LifecycleChecks(unittest.TestCase):
    def test_sdp_direction_fixtures(self):
        base='v=0\na=inactive\nm=video 9 UDP/TLS/RTP/SAVPF 96\na=mid:screen\na=msid:screen-peer track\n'
        self.assertFalse(allowed(base,'screen',True))
        self.assertTrue(allowed(base+'a=sendonly\n','screen',True))
        self.assertFalse(allowed(base.replace('video 9','video 0')+'a=sendonly\n','screen',True))
        self.assertFalse(allowed(base+'a=sendonly\n','camera',True))
        self.assertFalse(allowed(base+'a=sendonly\n',None,True))
        remote='v=0\na=recvonly\nm=video 9 UDP/TLS/RTP/SAVPF 96\na=mid:screen\n'
        self.assertTrue(allowed(remote,'screen',False))
        self.assertFalse(allowed(remote+'a=inactive\n','screen',False))
        self.assertFalse(allowed(remote.replace('video 9','video 0/2'),'screen',False))
        self.assertFalse(allowed(remote+'m=video 9 UDP/TLS/RTP/SAVPF 96\na=mid:other\na=sendrecv\n','missing',False))
    def test_source_contracts(self):
        peer=read('MeetingKit/Core/PeerSession.swift')
        self.assertIn('addTransceiver(with: track, init: configuration)',peer)
        self.assertIn('configuration.direction = .sendOnly',peer)
        self.assertEqual(peer.count('Self.screenMLineAcceptsSend('),3)
        self.assertIn('$0.mid == mid && $0.screen && !$0.rejected',peer)
        self.assertIn('current?.direction = sessionDirection',peer)
        for path in ['Shared/SharedFrameStore.swift','Shared/ScreenShareSignal.swift']:
            self.assertIn('[.atomic, .completeFileProtectionUntilFirstUserAuthentication]',read(path))
        sample=read('BroadcastExtension/SampleHandler.swift')
        heartbeat=sample.split('private func publishHeartbeat() {')[1].split('private func beginEncoding')[0]
        self.assertLess(heartbeat.index('defer { stateLock.unlock() }'),heartbeat.index('ScreenShareStore.touchHeartbeat'))
        self.assertIn('guard !stopping else { return }',heartbeat)
        capture=read('MeetingKit/Core/InAppScreenCapturer.swift')
        self.assertEqual(capture.count('self.acceptsCallback(epoch: captureEpoch)'),2)
        self.assertIn('let busy = running || stoppingCapture',capture)
        rtc=read('MeetingKit/Core/RealRTCClient.swift')
        for name in ['handleEnterBackground()', 'handleEnterForeground()', 'handleAudioInterruptionEnded(rawType: UInt?)']:
            self.assertIn('private func '+name+' {\n        guard isJoined else { return }',rtc)
if __name__=='__main__': unittest.main()
