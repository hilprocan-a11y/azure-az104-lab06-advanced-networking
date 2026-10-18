#!/bin/sh
# Read the same private blob using this VM's system-assigned managed identity.
# No SDK installation, account key or SAS is required. Never print the token.
set -eu

# Adapt this default to the globally unique account chosen for your reproduction.
: "${LAB06_STORAGE_ACCOUNT:=sthnlab06networking}"
export LAB06_STORAGE_ACCOUNT

if ! command -v python3 >/dev/null 2>&1; then
  echo 'PREREQUISITE_FAILED: python3 is not installed.'
  exit 1
fi

python3 - <<'PY'
import json
import os
import socket
import sys
import urllib.error
import urllib.parse
import urllib.request

host = os.environ['LAB06_STORAGE_ACCOUNT'] + '.blob.core.windows.net'
blob_url = 'https://' + host + '/endpoint-tests/endpoint-test.txt'
print('VM_HOSTNAME:', socket.gethostname(), flush=True)
print('STORAGE_HOST:', host, flush=True)

try:
    addresses = sorted({entry[4][0] for entry in socket.getaddrinfo(
        host, 443, socket.AF_INET, socket.SOCK_STREAM)})
    print('DNS_IPV4:', ', '.join(addresses), flush=True)
except socket.gaierror as exc:
    print('DNS_LOOKUP_FAILED:', str(exc), flush=True)
    sys.exit(2)

# IMDS requests must bypass proxies and include the Metadata header.
query = urllib.parse.urlencode({
    'api-version': '2018-02-01',
    'resource': 'https://storage.azure.com/',
})
token_request = urllib.request.Request(
    'http://169.254.169.254/metadata/identity/oauth2/token?' + query,
    headers={'Metadata': 'true'},
)
direct = urllib.request.build_opener(urllib.request.ProxyHandler({}))
try:
    with direct.open(token_request, timeout=10) as response:
        access_token = json.load(response)['access_token']
    print('MANAGED_IDENTITY_TOKEN: acquired (not displayed)', flush=True)
except urllib.error.HTTPError as exc:
    print('IDENTITY_TOKEN_FAILED_HTTP:', exc.code, flush=True)
    sys.exit(3)
except (urllib.error.URLError, TimeoutError, ValueError, KeyError) as exc:
    print('IDENTITY_TOKEN_FAILED:', type(exc).__name__, flush=True)
    sys.exit(3)

request = urllib.request.Request(blob_url, headers={
    'Authorization': 'Bearer ' + access_token,
    'x-ms-version': '2023-11-03',
})
try:
    with direct.open(request, timeout=15) as response:
        body = response.read(4096)
        print('BLOB_HTTP_STATUS:', response.status, flush=True)
        print('BLOB_CONTENT:', body.decode('utf-8', errors='replace').strip(), flush=True)
except urllib.error.HTTPError as exc:
    print('BLOB_HTTP_STATUS:', exc.code, flush=True)
    print('STORAGE_ERROR_CODE:', exc.headers.get('x-ms-error-code', 'not supplied'), flush=True)
    print('STORAGE_REQUEST_ID:', exc.headers.get('x-ms-request-id', 'not supplied'), flush=True)
    sys.exit(4)
except (urllib.error.URLError, TimeoutError) as exc:
    print('BLOB_CONNECTION_FAILED:', type(exc).__name__, flush=True)
    sys.exit(5)
PY
