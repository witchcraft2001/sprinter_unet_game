#!/usr/bin/env python3
"""echo_server.py -- the peer of the M stand: TCP and UDP echo on 127.0.0.1.

The MAME ESP-AT device opens real host sockets, so the library under test
talks to this process through the emulated SprinterESP card.

  echo_server.py [--port 7000] [--close-after N] [--log FILE]

--close-after N: a TCP connection is closed by the server once it has
echoed N bytes (the "peer closes" scenario).  Every connection, datagram
and byte count is logged (one line each) for the evidence directory.
"""
import argparse
import selectors
import socket
import sys
import time


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--host', default='127.0.0.1')
    ap.add_argument('--port', type=int, default=7000)
    ap.add_argument('--close-after', type=int, default=0)
    ap.add_argument('--log', default=None)
    a = ap.parse_args()
    log = open(a.log, 'a', buffering=1) if a.log else sys.stdout

    def note(*parts):
        log.write('%.3f %s\n' % (time.time(), ' '.join(str(p) for p in parts)))

    sel = selectors.DefaultSelector()
    lst = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    lst.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    lst.bind((a.host, a.port))
    lst.listen(4)
    lst.setblocking(False)
    sel.register(lst, selectors.EVENT_READ, 'accept')
    udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    udp.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    udp.bind((a.host, a.port))
    udp.setblocking(False)
    sel.register(udp, selectors.EVENT_READ, 'udp')
    echoed = {}
    note('listening', a.host, a.port, 'close-after', a.close_after)
    print('ready', flush=True)
    while True:
        for key, _ in sel.select(1.0):
            if key.data == 'accept':
                c, peer = lst.accept()
                c.setblocking(False)
                c.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
                sel.register(c, selectors.EVENT_READ, 'tcp')
                echoed[c] = 0
                note('tcp connect', peer)
            elif key.data == 'udp':
                d, peer = udp.recvfrom(4096)
                udp.sendto(d, peer)
                note('udp', peer, len(d))
            else:
                c = key.fileobj
                try:
                    d = c.recv(4096)
                except ConnectionError:
                    d = b''
                if not d:
                    note('tcp closed by the client', echoed.pop(c, 0))
                    sel.unregister(c)
                    c.close()
                    continue
                if a.close_after:
                    d = d[:max(0, a.close_after - echoed[c])]
                c.sendall(d)
                echoed[c] += len(d)
                note('tcp echo', len(d), 'total', echoed[c])
                if a.close_after and echoed[c] >= a.close_after:
                    note('tcp close by the server after', echoed[c])
                    sel.unregister(c)
                    echoed.pop(c, None)
                    c.close()


if __name__ == '__main__':
    main()
