#!/usr/bin/env python3

import json
import logging
import os
import re
import socket
import socketserver
from argparse import ArgumentParser
from concurrent.futures import ThreadPoolExecutor, as_completed
from http import HTTPStatus
from http.client import HTTPException, HTTPResponse
from http.server import BaseHTTPRequestHandler
from urllib.parse import urlencode


FOREMAN_SOCKET = os.environ.get("FOREMAN_SOCKET", "/run/foreman.sock")
FOREMAN_PROVISION_PATH = "/unattended/provision"
MAX_REQUEST_BYTES = 131_072
MAC_PATTERN = re.compile(r"^[0-9a-f]{2}(?::[0-9a-f]{2}){5}$")
LOG = logging.getLogger("proxmox-foreman-answer")


def normalized_macs(payload):
    interfaces = payload.get("network_interfaces")
    if not isinstance(interfaces, list):
        return []

    macs = []
    for interface in interfaces:
        if not isinstance(interface, dict):
            continue
        mac = interface.get("mac", "").strip().lower()
        if MAC_PATTERN.fullmatch(mac) and mac not in macs:
            macs.append(mac)
    return macs


def fetch_answer(mac):
    connection = UnixSocketHTTPConnection(FOREMAN_SOCKET, timeout=30)
    try:
        connection.request(
            "GET",
            f"{FOREMAN_PROVISION_PATH}?{urlencode({'mac': mac})}",
            headers={"Accept": "application/toml, text/plain;q=0.5", "Host": "localhost"},
        )
        remote = connection.getresponse()
        return remote.status, remote.read()
    finally:
        connection.close()


class UnixSocketHTTPConnection:
    def __init__(self, socket_path, timeout):
        self.socket_path = socket_path
        self.timeout = timeout
        self.sock = None

    def request(self, method, target, headers):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(self.timeout)
        self.sock.connect(self.socket_path)
        header_lines = "".join(f"{name}: {value}\r\n" for name, value in headers.items())
        self.sock.sendall(f"{method} {target} HTTP/1.1\r\n{header_lines}\r\n".encode())

    def getresponse(self):
        response = HTTPResponse(self.sock)
        response.begin()
        return response

    def close(self):
        if self.sock:
            self.sock.close()


def handle_request(method, content_type, body):
    if method != "POST":
        return HTTPStatus.METHOD_NOT_ALLOWED, b"Only POST is supported.\n"
    if not content_type.startswith("application/json"):
        return HTTPStatus.UNSUPPORTED_MEDIA_TYPE, b"Expected application/json request body.\n"
    if len(body) > MAX_REQUEST_BYTES:
        return HTTPStatus.REQUEST_ENTITY_TOO_LARGE, b"Request body is too large.\n"

    try:
        payload = json.loads(body)
    except json.JSONDecodeError:
        return HTTPStatus.BAD_REQUEST, b"Invalid JSON request body.\n"

    macs = normalized_macs(payload)
    if not macs:
        return HTTPStatus.BAD_REQUEST, b"No valid network interface MAC address was supplied.\n"

    last_not_found = None
    lookup_failed = False
    executor = ThreadPoolExecutor(max_workers=len(macs), thread_name_prefix="foreman-answer")
    futures = {executor.submit(fetch_answer, mac): mac for mac in macs}
    try:
        for future in as_completed(futures):
            mac = futures[future]
            try:
                status, answer = future.result()
            except (HTTPException, OSError, TimeoutError):
                LOG.exception("Foreman unattended provisioning request failed for MAC %s", mac)
                lookup_failed = True
                continue
            if status != HTTPStatus.NOT_FOUND:
                return status, answer
            last_not_found = answer
    finally:
        # Do not make a matching MAC wait for unrelated socket timeouts.
        executor.shutdown(wait=False, cancel_futures=True)

    if lookup_failed:
        return (
            HTTPStatus.BAD_GATEWAY,
            b"Foreman unattended provisioning request failed. "
            b"Check proxmox-foreman-answer.service logs.\n",
        )

    return HTTPStatus.NOT_FOUND, last_not_found or b"No Foreman host matched the supplied MAC addresses.\n"


def safe_handle_request(method, content_type, body):
    try:
        return handle_request(method, content_type, body)
    except Exception:
        LOG.exception("Unexpected answer adapter request failure")
        return (
            HTTPStatus.INTERNAL_SERVER_ERROR,
            b"Unexpected answer adapter failure. Check proxmox-foreman-answer.service logs.\n",
        )


class AnswerRequestHandler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        return

    def do_POST(self):
        try:
            content_length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            status, answer = HTTPStatus.BAD_REQUEST, b"Invalid Content-Length.\n"
        else:
            status, answer = safe_handle_request(
                "POST", self.headers.get("Content-Type", ""), self.rfile.read(content_length)
            )
        self.respond(status, answer)

    def do_GET(self):
        status, answer = safe_handle_request("GET", self.headers.get("Content-Type", ""), b"")
        self.respond(status, answer)

    def respond(self, status, answer):
        self.send_response(status)
        self.send_header(
            "Content-Type",
            "application/toml; charset=utf-8" if status == HTTPStatus.OK else "text/plain; charset=utf-8",
        )
        self.send_header("Content-Length", str(len(answer)))
        self.end_headers()
        self.wfile.write(answer)


class UnixHTTPServer(socketserver.UnixStreamServer):
    allow_reuse_address = True


def main():
    parser = ArgumentParser()
    parser.add_argument("--socket", required=True)
    args = parser.parse_args()
    if os.path.exists(args.socket):
        os.unlink(args.socket)
    with UnixHTTPServer(args.socket, AnswerRequestHandler) as server:
        server.serve_forever()


if __name__ == "__main__":
    main()
