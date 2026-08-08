#!/usr/bin/env python3
"""
MEHEN secure-link visual agent v1.0.24.

Purpose:
  - Runs on AUP1/AUP2 for the MEHEN two-AUP demo.
  - Uses board TRNG output when available for nonce/session material.
  - Implements an ASCON-128 AEAD packet link in Python for visible packet exchange.
  - Writes simple logs/metrics so the Windows mission-control dashboard can animate the channel.

Notes:
  The MEHEN hardware service is still proven by the existing board scripts:
    test_trng_axi.py, run_ascon_full_kat.py, bench_mehen_hw.py, and F' SecureLaneBridge.
  This link agent is a thin demo-layer packet mover so the audience can see ciphertext, tags,
  accepted packets, and rejected tampered packets across the AUP1/AUP2 boundary.
"""
import argparse
import base64
import hashlib
import hmac
import json
import os
import socket
import subprocess
import sys
import time
from pathlib import Path

MASK = (1 << 64) - 1
RC = [0xF0,0xE1,0xD2,0xC3,0xB4,0xA5,0x96,0x87,0x78,0x69,0x5A,0x4B]
IV_ASCON128 = 0x80400C0600000000
SECRET_DEFAULT = "MEHEN-DEMO-MISSION-SECRET-v1"
LOG_PATH = Path("/tmp/mehen_link_agent.log")
METRICS_PATH = Path("/tmp/mehen_link_metrics.json")


def now_ms():
    return int(time.time() * 1000)


def log(msg, **kv):
    line = {"ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "msg": msg}
    line.update(kv)
    text = json.dumps(line, sort_keys=True)
    print(text, flush=True)
    try:
        with LOG_PATH.open("a", encoding="utf-8") as f:
            f.write(text + "\n")
    except Exception:
        pass


def write_metrics(**kv):
    data = {}
    try:
        if METRICS_PATH.exists():
            data = json.loads(METRICS_PATH.read_text(encoding="utf-8"))
    except Exception:
        data = {}
    data.update(kv)
    data["updated_utc"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    try:
        METRICS_PATH.write_text(json.dumps(data, indent=2, sort_keys=True), encoding="utf-8")
    except Exception:
        pass


def rotr(x, n):
    return ((x >> n) | ((x & ((1 << n) - 1)) << (64 - n))) & MASK


def p_round(s, c):
    x0,x1,x2,x3,x4 = s
    x2 ^= c
    x0 ^= x4; x4 ^= x3; x2 ^= x1
    t0 = (~x0) & x1
    t1 = (~x1) & x2
    t2 = (~x2) & x3
    t3 = (~x3) & x4
    t4 = (~x4) & x0
    x0 ^= t1; x1 ^= t2; x2 ^= t3; x3 ^= t4; x4 ^= t0
    x1 ^= x0; x0 ^= x4; x3 ^= x2; x2 = (~x2) & MASK
    x0 ^= rotr(x0,19) ^ rotr(x0,28)
    x1 ^= rotr(x1,61) ^ rotr(x1,39)
    x2 ^= rotr(x2,1) ^ rotr(x2,6)
    x3 ^= rotr(x3,10) ^ rotr(x3,17)
    x4 ^= rotr(x4,7) ^ rotr(x4,41)
    return [x0&MASK,x1&MASK,x2&MASK,x3&MASK,x4&MASK]


def perm(s, rounds):
    start = 12 - rounds
    for c in RC[start:]:
        s = p_round(s, c)
    return s


def bytes_to_u64(b):
    return int.from_bytes(b, "big")


def u64_to_bytes(x):
    return int(x & MASK).to_bytes(8, "big")


def pad_block(b):
    return b + b"\x80" + b"\x00" * (7 - len(b))


def ascon_init(key, nonce):
    k0 = bytes_to_u64(key[:8]); k1 = bytes_to_u64(key[8:])
    n0 = bytes_to_u64(nonce[:8]); n1 = bytes_to_u64(nonce[8:])
    s = [IV_ASCON128, k0, k1, n0, n1]
    s = perm(s, 12)
    s[3] ^= k0; s[4] ^= k1
    return s, k0, k1


def absorb_ad(s, ad):
    if ad:
        off = 0
        while off + 8 <= len(ad):
            s[0] ^= bytes_to_u64(ad[off:off+8])
            s = perm(s, 6)
            off += 8
        last = ad[off:]
        s[0] ^= bytes_to_u64(pad_block(last))
        s = perm(s, 6)
    s[4] ^= 1
    return s


def ascon_encrypt(key, nonce, ad, plaintext):
    s,k0,k1 = ascon_init(key, nonce)
    s = absorb_ad(s, ad)
    ct = bytearray()
    off = 0
    while off + 8 <= len(plaintext):
        s[0] ^= bytes_to_u64(plaintext[off:off+8])
        ct += u64_to_bytes(s[0])
        s = perm(s, 6)
        off += 8
    last = plaintext[off:]
    if len(last) > 0:
        s[0] ^= bytes_to_u64(pad_block(last))
        ct += u64_to_bytes(s[0])[:len(last)]
    else:
        s[0] ^= bytes_to_u64(pad_block(b""))
    s[1] ^= k0; s[2] ^= k1
    s = perm(s, 12)
    s[3] ^= k0; s[4] ^= k1
    tag = u64_to_bytes(s[3]) + u64_to_bytes(s[4])
    return bytes(ct), tag


def ascon_decrypt(key, nonce, ad, ciphertext, tag):
    s,k0,k1 = ascon_init(key, nonce)
    s = absorb_ad(s, ad)
    pt = bytearray()
    off = 0
    while off + 8 <= len(ciphertext):
        c = bytes_to_u64(ciphertext[off:off+8])
        m = s[0] ^ c
        pt += u64_to_bytes(m)
        s[0] = c
        s = perm(s, 6)
        off += 8
    last = ciphertext[off:]
    if len(last) > 0:
        s0b = bytearray(u64_to_bytes(s[0]))
        mb = bytearray()
        for i,b in enumerate(last):
            mb.append(s0b[i] ^ b)
            s0b[i] = b
        s0b[len(last)] ^= 0x80
        s[0] = bytes_to_u64(bytes(s0b))
        pt += bytes(mb)
    else:
        s[0] ^= bytes_to_u64(pad_block(b""))
    s[1] ^= k0; s[2] ^= k1
    s = perm(s, 12)
    s[3] ^= k0; s[4] ^= k1
    calc = u64_to_bytes(s[3]) + u64_to_bytes(s[4])
    ok = hmac.compare_digest(calc, tag)
    return bytes(pt), ok, calc


def get_temp_c():
    vals = []
    for p in Path("/sys/class/thermal").glob("thermal_zone*/temp"):
        try:
            vals.append(float(p.read_text().strip()) / 1000.0)
        except Exception:
            pass
    return max(vals) if vals else None


def get_trng_nonce(spaccomputing="/home/xilinx/spaccomputing"):
    # Prefer real board TRNG via existing MEHEN script. Fallback is os.urandom.
    try:
        cmd = "cd {0} && source /etc/profile.d/xrt_setup.sh 2>/dev/null || true; sudo -E /usr/local/share/pynq-venv/bin/python3 test_trng_axi.py".format(spaccomputing)
        out = subprocess.check_output(["bash", "-lc", cmd], text=True, stderr=subprocess.STDOUT, timeout=20)
        words = []
        for line in out.splitlines():
            if "rand=0x" in line.lower():
                hx = line.lower().split("rand=0x",1)[1].strip().split()[0]
                words.append(int(hx,16).to_bytes(4,"big"))
        if len(words) >= 4 and "PASS: TRNG" in out:
            nonce = b"".join(words[:4])[:16]
            return nonce, "TRNG", out
        return os.urandom(16), "OS_FALLBACK", out
    except Exception as e:
        return os.urandom(16), "OS_FALLBACK", str(e)


def derive_key(secret, nonce1, nonce2):
    raw = hashlib.sha256(secret.encode() + b"|MEHEN|" + nonce1 + nonce2).digest()
    return raw[:16], hashlib.sha256(raw).hexdigest()[:12].upper()


def short_fp(data, n=8):
    return hashlib.sha256(data).hexdigest()[:n].upper()


def send_json(sock, obj):
    data = json.dumps(obj).encode() + b"\n"
    sock.sendall(data)


def recv_json(sock):
    buf = b""
    while not buf.endswith(b"\n"):
        chunk = sock.recv(4096)
        if not chunk:
            raise ConnectionError("socket closed")
        buf += chunk
    return json.loads(buf.decode())


def handle_client(conn, addr, args):
    peer = addr[0]
    hello = recv_json(conn)
    if hello.get("type") == "PING":
        send_json(conn, {"type":"PONG", "host":socket.gethostname(), "ts":time.time()})
        log("PING_OK", peer=peer)
        return
    if hello.get("type") != "HELLO":
        raise ValueError("expected HELLO")
    nonce1 = base64.b64decode(hello["nonce1_b64"])
    direction = hello.get("direction", "UNKNOWN")
    nonce2, src, trng_log = get_trng_nonce(args.spaccomputing)
    key, fp = derive_key(args.secret, nonce1, nonce2)
    temp = get_temp_c()
    n1fp = short_fp(nonce1)
    n2fp = short_fp(nonce2)
    send_json(conn, {"type":"HELLO_ACK", "nonce2_b64":base64.b64encode(nonce2).decode(), "key_fp":fp, "nonce1_fp":n1fp, "nonce2_fp":n2fp, "trng_source":src, "temp_c":temp})
    log("SESSION_READY", role="receiver", peer=peer, direction=direction, key_fp=fp, nonce1_fp=n1fp, nonce2_fp=n2fp, trng_source=src, temp_c=temp)
    write_metrics(channel_state="READY", key_fp=fp, nonce1_fp=n1fp, nonce2_fp=n2fp, receiver_temp_c=temp, receiver_trng=src)

    pkt = recv_json(conn)
    if pkt.get("type") != "DATA":
        raise ValueError("expected DATA")
    t0 = now_ms()
    seq = int(pkt.get("seq", 0))
    ad = base64.b64decode(pkt["ad_b64"])
    nonce = base64.b64decode(pkt["packet_nonce_b64"])
    ct = base64.b64decode(pkt["ciphertext_b64"])
    tag = base64.b64decode(pkt["tag_b64"])
    pt, ok, calc = ascon_decrypt(key, nonce, ad, ct, tag)
    latency = max(0.0, now_ms() - t0)
    tag_fp = tag.hex().upper()[:12]
    if ok:
        status = "PASS"
        msg = "PACKET_ACCEPTED"
    else:
        status = "BAD_TAG"
        msg = "PACKET_REJECTED"
    send_json(conn, {"type":"DATA_ACK", "seq":seq, "verify":status, "latency_ms":latency, "tag_fp":tag_fp, "plaintext":pt.decode(errors="replace") if ok else ""})
    log(msg, role="receiver", direction=direction, seq=seq, verify=status, tag_fp=tag_fp, bytes=len(ct)+len(tag), latency_ms=latency)
    write_metrics(last_direction=direction, last_seq=seq, verify=status, tag_fp=tag_fp, bytes_received=len(ct)+len(tag), decrypt_latency_ms=latency, channel_state=("ALERT" if not ok else "READY"))


def receiver(args):
    LOG_PATH.unlink(missing_ok=True)
    log("MEHEN_RECEIVER_START", host=socket.gethostname(), listen=args.listen, port=args.port)
    write_metrics(node=socket.gethostname(), receiver="RUNNING", channel_state="WAIT")
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind((args.listen, args.port))
    s.listen(5)
    while True:
        conn, addr = s.accept()
        with conn:
            try:
                handle_client(conn, addr, args)
            except Exception as e:
                log("RECEIVER_ERROR", error=str(e), peer=addr[0] if addr else "?")
                write_metrics(last_error=str(e), channel_state="ERROR")


def decode_payload(args):
    if getattr(args, "payload_b64", None):
        return base64.b64decode(args.payload_b64).decode("utf-8", errors="replace")
    return args.payload


def ping(args):
    with socket.create_connection((args.peer, args.port), timeout=args.timeout) as sock:
        send_json(sock, {"type":"PING"})
        resp = recv_json(sock)
    ok = resp.get("type") == "PONG"
    print("PING_RESULT {0} peer={1} port={2}".format("PASS" if ok else "FAIL", args.peer, args.port))
    return 0 if ok else 1


def sender(args):
    nonce1, src, trng_log = get_trng_nonce(args.spaccomputing)
    seq = int(time.time()) % 100000
    direction = args.direction
    t0 = now_ms()
    with socket.create_connection((args.peer, args.port), timeout=15) as sock:
        send_json(sock, {"type":"HELLO", "nonce1_b64":base64.b64encode(nonce1).decode(), "direction":direction})
        ack = recv_json(sock)
        nonce2 = base64.b64decode(ack["nonce2_b64"])
        key, fp = derive_key(args.secret, nonce1, nonce2)
        if fp != ack.get("key_fp"):
            raise RuntimeError("key fingerprint mismatch")
        n1fp = ack.get("nonce1_fp", short_fp(nonce1))
        n2fp = ack.get("nonce2_fp", short_fp(nonce2))
        print("MISSION_EVENT TRNG_SESSION_READY direction={0} AUP1_NONCE_FP={1} AUP2_NONCE_FP={2} KEY_FP={3}".format(direction, n1fp, n2fp, fp), flush=True)
        payload = decode_payload(args).encode()
        ad_text = "MEHEN|{0}|seq={1}|ts={2}".format(direction, seq, int(time.time()))
        ad = ad_text.encode()
        packet_nonce = hashlib.sha256(nonce1 + nonce2 + str(seq).encode()).digest()[:16]
        enc_t0 = now_ms()
        ct, tag = ascon_encrypt(key, packet_nonce, ad, payload)
        enc_dt = max(0.0, now_ms() - enc_t0)
        if args.tamper:
            ct = bytes([ct[0] ^ 0x01]) + ct[1:] if ct else b"\x01"
        tag_fp = tag.hex().upper()[:12]
        print("MISSION_EVENT AEAD_ENCRYPT_DONE direction={0} seq={1} ciphertext_bytes={2} tag_bytes={3} tag_fp={4} encrypt_ms={5:.3f}".format(direction, seq, len(ct), len(tag), tag_fp, enc_dt), flush=True)
        send_json(sock, {"type":"DATA", "seq":seq, "ad_b64":base64.b64encode(ad).decode(), "packet_nonce_b64":base64.b64encode(packet_nonce).decode(), "ciphertext_b64":base64.b64encode(ct).decode(), "tag_b64":base64.b64encode(tag).decode()})
        data_ack = recv_json(sock)
    dt = max(0.0, now_ms() - t0)
    verify = data_ack.get("verify", "UNKNOWN")
    channel = "ALERT" if verify != "PASS" else "READY"
    dec_ms = data_ack.get("latency_ms")
    print("MISSION_EVENT AEAD_DECRYPT_VERIFY_{0} direction={1} seq={2} decrypt_ms={3}".format("PASS" if verify == "PASS" else "BAD_TAG_REJECT", direction, seq, dec_ms), flush=True)
    log("PACKET_SENT", role="sender", direction=direction, seq=seq, key_fp=fp, nonce1_fp=n1fp, nonce2_fp=n2fp, tag_fp=tag_fp, verify=verify, ciphertext_bytes=len(ct), tag_bytes=len(tag), latency_ms=dt, decrypt_latency_ms=dec_ms, tamper=args.tamper, sender_trng=src, receiver_trng=ack.get("trng_source"))
    write_metrics(channel_state=channel, key_fp=fp, nonce1_fp=n1fp, nonce2_fp=n2fp, last_direction=direction, last_seq=seq, verify=verify, tag_fp=tag_fp, bytes_sent=len(ct)+len(tag), encrypt_latency_ms=enc_dt, total_latency_ms=dt, decrypt_latency_ms=dec_ms, sender_trng=src, receiver_trng=ack.get("trng_source"), sender_temp_c=get_temp_c(), receiver_temp_c=ack.get("temp_c"))
    print("KEY_EXCHANGE AUP1_NONCE_FP={0} AUP2_NONCE_FP={1} KEY_FP={2}".format(n1fp, n2fp, fp))
    print("SESSION_READY key_fp={0}".format(fp))
    print("PACKET_SENT direction={0} seq={1} ciphertext_bytes={2} tag_bytes={3} tag_fp={4}".format(direction, seq, len(ct), len(tag), tag_fp))
    print("VERIFY_RESULT {0}".format(verify))
    print("LATENCY_MS {0:.3f}".format(dt))
    print("ENCRYPT_MS {0:.3f}".format(enc_dt))
    if dec_ms is not None:
        print("DECRYPT_MS {0:.3f}".format(float(dec_ms)))
    if verify == "PASS":
        print("PACKET_ACCEPTED")
        return 0
    print("PACKET_REJECTED")
    return 2 if args.tamper else 1


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("receiver")
    r.add_argument("--listen", default="0.0.0.0")
    r.add_argument("--port", type=int, default=9092)
    r.add_argument("--secret", default=SECRET_DEFAULT)
    r.add_argument("--spaccomputing", default="/home/xilinx/spaccomputing")
    s = sub.add_parser("send")
    s.add_argument("--peer", required=True)
    s.add_argument("--port", type=int, default=9092)
    s.add_argument("--payload", default="MEHEN secure telemetry packet")
    s.add_argument("--payload-b64", default=None)
    s.add_argument("--direction", default="AUP1_TO_AUP2")
    s.add_argument("--tamper", action="store_true")
    s.add_argument("--secret", default=SECRET_DEFAULT)
    s.add_argument("--spaccomputing", default="/home/xilinx/spaccomputing")
    q = sub.add_parser("ping")
    q.add_argument("--peer", required=True)
    q.add_argument("--port", type=int, default=9092)
    q.add_argument("--timeout", type=float, default=5.0)
    args = ap.parse_args()
    if args.cmd == "receiver":
        receiver(args)
        return 0
    if args.cmd == "send":
        return sender(args)
    if args.cmd == "ping":
        return ping(args)
    return 1

if __name__ == "__main__":
    sys.exit(main())
