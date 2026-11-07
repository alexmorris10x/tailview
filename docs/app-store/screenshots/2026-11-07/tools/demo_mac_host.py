#!/usr/bin/env python3
"""A stand-in Mac host for App Store screenshots.

It speaks the same wire protocol as the TailView Mac host (Shared/Packet.swift,
PairingRequest.swift) but streams a prepared demo desktop JPEG instead of a real
display, so the unmodified iOS app can pair, connect and render a session
through its real network and streaming code without showing anyone's desktop.

Run it on a tailnet machine that is not already running the Mac host (the iOS
app only connects to 100.x addresses on port 47820):

    python3 demo_mac_host.py --bind 100.x.y.z --frames one.jpg,two.jpg,three.jpg

A click in the left, middle or right third of the screen (a real `leftClick`
control command from a tap) picks frame 1, 2 or 3; the window buttons
(Left half, Right half, Fill) and typed digits work too.
Frame files are re-read for every frame.
It accepts any pairing code and saved credential: demo use only, never on a
network you don't control.
"""
import argparse
import json
import socket
import struct
import threading
import time

JPEG, CONTROL, CONTROL_STATE, MICROPHONE_STATE, VIDEO_FLOW, CAPABILITIES, PASTE = 1, 3, 4, 6, 8, 9, 12
PASTE_CAPABILITY = 2


def packet(kind, payload):
    return bytes([kind]) + struct.pack(">I", len(payload)) + payload


def read_line(conn):
    data = b""
    while not data.endswith(b"\n"):
        chunk = conn.recv(1)
        if not chunk or len(data) > 256:
            return None
        data += chunk
    return data.decode("utf-8", "replace").strip()


current = [0]


def serve(conn, addr, frames, interval):
    lock = threading.Lock()
    alive = True

    def send(data):
        with lock:
            conn.sendall(data)

    def send_frame():
        with open(frames[current[0]], "rb") as f:
            send(packet(JPEG, f.read()))

    try:
        line = read_line(conn)
        if line is None:
            return
        kind = line.split(" ", 1)[0]
        print(f"{addr[0]} sign-in: {kind if kind in ('PAIR', 'AUTH') else 'session code'}", flush=True)
        send(b"PAIRED\n" if kind == "PAIR" else b"OK\n")
        send(packet(CONTROL_STATE, b"\x01"))
        buffer = b""
        while alive:
            chunk = conn.recv(65536)
            if not chunk:
                break
            buffer += chunk
            while len(buffer) >= 5:
                k = buffer[0]
                length = struct.unpack(">I", buffer[1:5])[0]
                if len(buffer) < 5 + length:
                    break
                payload, buffer = buffer[5:5 + length], buffer[5 + length:]
                if k == CAPABILITIES:
                    send(packet(CAPABILITIES, bytes([PASTE_CAPABILITY])))
                elif k == VIDEO_FLOW and payload in (b"\x01", b"\x02"):
                    # One frame per acknowledgment, like the real host's credits.
                    if payload == b"\x01":
                        time.sleep(interval)
                    send_frame()
                elif k == CONTROL:
                    command = json.loads(payload)
                    text = command.get("text") or ""
                    pick = {"leftHalf": 1, "rightHalf": 2, "fill": 3}.get(command.get("window"))
                    if command.get("kind") == "text" and text.isdigit():
                        pick = int(text)
                    if command.get("kind") == "leftClick" and command.get("x") is not None:
                        pick = min(3, int(command["x"] * 3) + 1)
                    if pick and pick <= len(frames):
                        current[0] = pick - 1
                        text = str(pick)
                        print(f"frame {text}: {frames[current[0]]}", flush=True)
                    else:
                        print(f"control: {command}", flush=True)
    except OSError as error:
        print(f"{addr[0]} ended: {error}", flush=True)
    finally:
        alive = False
        conn.close()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--bind", required=True, help="this machine's tailnet IPv4 address")
    parser.add_argument("--frames", required=True, help="comma-separated JPEGs; a typed digit picks one")
    parser.add_argument("--interval", type=float, default=0.5, help="seconds between frames")
    args = parser.parse_args()
    server = socket.socket()
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind((args.bind, 47820))
    server.listen(4)
    frames = args.frames.split(",")
    print(f"demo Mac host on {args.bind}:47820 streaming {frames}", flush=True)
    while True:
        conn, addr = server.accept()
        conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        threading.Thread(target=serve, args=(conn, addr, frames, args.interval), daemon=True).start()


if __name__ == "__main__":
    main()
