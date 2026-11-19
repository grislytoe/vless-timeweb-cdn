"""Verify the origin certificate and HTTP/2 without disabling TLS verification."""
import argparse
import socket
import ssl

def check(domain, address, port):
    context = ssl.create_default_context()
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    context.set_alpn_protocols(['h2'])
    with socket.create_connection((address, port), timeout=10) as raw:
        with context.wrap_socket(raw, server_hostname=domain) as tls:
            if tls.selected_alpn_protocol() != 'h2':
                raise RuntimeError('Origin did not negotiate H2.')
    print('Verified origin certificate and H2.')

if __name__ == '__main__':
    p = argparse.ArgumentParser()
    p.add_argument('--domain', required=True)
    p.add_argument('--address', required=True)
    p.add_argument('--port', type=int, default=443)
    a = p.parse_args()
    check(a.domain, a.address, a.port)
