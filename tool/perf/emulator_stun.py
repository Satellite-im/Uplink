#!/usr/bin/env python3
"""A STUN server for two Android emulators on one Mac: it answers each with the address the OTHER emulator can reach
it at (10.0.2.2, the Mac as an emulator sees it, and the port its packets left the Mac's side from). Listens on this
Mac alone."""
import socket, struct
COOKIE = 0x2112A442
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.bind(('127.0.0.1', 34780))
n = 0
while True:
    data, (ip, port) = s.recvfrom(2048)
    if len(data) < 20:
        continue
    typ, length, cookie = struct.unpack('!HHI', data[:8])
    if typ != 0x0001 or cookie != COOKIE:
        continue
    xport = port ^ (COOKIE >> 16)
    xaddr = struct.unpack('!I', socket.inet_aton('10.0.2.2'))[0] ^ COOKIE
    attr = struct.pack('!HHBBHI', 0x0020, 8, 0, 1, xport, xaddr)
    s.sendto(struct.pack('!HHI', 0x0101, len(attr), COOKIE) + data[8:20] + attr, (ip, port))
    n += 1
    if n <= 20 or n % 200 == 0:
        print(f'answered {ip}:{port} ({n})', flush=True)
