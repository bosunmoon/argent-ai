# Argent Vision API

A thin FastAPI wrapper around the existing, compiled `argent-vision` CLI. It
never builds Swift or implements image analysis in Python.

```text
Ubuntu Argent AI -> multipart HTTP POST -> Mac Pro FastAPI (8060)
                 -> existing argent-vision subprocess -> Apple Vision -> JSON
```

Python 3.9+ and the existing executable are required. Startup fails if the
configured binary is missing, not executable, or not an absolute path.

## Setup and launch

```bash
cd /Users/mike/argent-ai/apple-vision-api
python3 -m venv .venv
source .venv/bin/activate
python -m pip install -r requirements.txt
cp .env.example .env
# Edit .env if needed, then load it into the shell:
set -a
source .env
set +a
uvicorn main:app --host 0.0.0.0 --port 8060
```

The application reads environment variables at import time. `.env` is a shell
configuration example and is not loaded automatically. Restart after changes.

| Variable | Default | Meaning |
| --- | --- | --- |
| `ARGENT_VISION_BINARY` | `/Users/mike/argent-ai/apple-vision/.build/argent-vision` | Absolute executable path |
| `ARGENT_VISION_TIMEOUT` | `10` | Positive subprocess timeout in seconds |
| `ARGENT_VISION_API_KEY` | empty | When set, require `X-API-Key` on `/analyze` |

To enable authentication, set `ARGENT_VISION_API_KEY=test-key` in `.env` before
loading it, or run `export ARGENT_VISION_API_KEY=test-key` before launching.
Use a strong key for LAN deployment. Binding to `0.0.0.0` makes the service
available on the Mac's network interfaces; restrict access to the trusted LAN.

## Requests

```bash
curl http://127.0.0.1:8060/health
curl http://127.0.0.1:8060/version
curl --fail-with-body -X POST \
  -H 'X-API-Key: test-key' \
  -F 'image=@/Users/mike/argent-ai/deck.jpg;type=image/jpeg' \
  http://127.0.0.1:8060/analyze
```

Omit the API key header when authentication is disabled. For PNG, use
`type=image/png`. From Ubuntu, replace `127.0.0.1` with the Mac's LAN IP and
use the path to the image on Ubuntu.

`/health` returns `{"status":"ok"}` and `/version` reports service name and
version. These endpoints do not require authentication or execute the CLI.

`/analyze` accepts the multipart field `image`, checks its MIME type and leading
JPEG/PNG signature, and copies at most 10 MiB of image bytes into a unique
`tempfile` file. Signature checking is not full image decoding; Apple Vision
handles decoding. FastAPI parses/spools multipart uploads before the endpoint
checks image size; the limit is on the image, not the entire HTTP request body.
Use an upstream body limit if you need to bound total incoming request size.

The synchronous handler runs in FastAPI's worker thread pool. It invokes
`subprocess.run([binary, temporary_path])` without a shell and captures both
output streams. On success it parses stdout to validate JSON, then returns the
original JSON bytes without adding fields or changing values. This intentionally
preserves the CLI's `image` field, including its temporary path. Clients cannot
choose local paths or executable arguments. Temporary files are deleted in a
`finally` block after success or failure.

Errors: 401 for an invalid/missing configured key, 413 for an oversized image,
415 for unsupported MIME/signature, 422 for a missing image field, 500 for CLI
execution failure, 504 for timeout, and 502 for invalid CLI JSON. Nonzero exits
include the return code; diagnostic stderr is logged server-side to avoid
exposing filesystem paths in error responses. Logs include upload metadata,
subprocess duration and return code when available. Temporary path logging is
at debug level (`--log-level debug`). Image contents and API keys are not logged.

## Unit tests

```bash
cd /Users/mike/argent-ai/apple-vision-api
source .venv/bin/activate
python -m pip install -r requirements-dev.txt
python -m unittest discover -s tests -v
```

Tests mock the subprocess and substitute the Python executable for startup
validation; no Vision binary, Swift build, or Apple frameworks are needed.
