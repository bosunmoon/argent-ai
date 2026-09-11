# argent-vision

`argent-vision` is a local macOS command-line prototype for Argent AI. It uses
Apple's Vision framework to detect human figures and classify a still image. It
has no third-party dependencies. Images are processed locally.

## Requirements

- macOS 11 or later
- Xcode Command Line Tools with Swift 5.7 or later

## Build

```bash
cd apple-vision
swift build -c release
```

The executable is written to `.build/release/argent-vision`. To make the short
command available globally, copy it to a directory on your `PATH` or create a
symlink to it.

## Usage

```bash
.build/release/argent-vision /tmp/deck.jpg
```

The default image-classification confidence threshold is `0.50`. Set it with:

```bash
.build/release/argent-vision --confidence-threshold 0.70 /tmp/deck.jpg
```

The threshold must be between `0.0` and `1.0`. At most the first 10 Vision
classification results that meet the threshold are returned. Bounding boxes use
Vision's normalized, lower-left-origin coordinate system.

Successful output is JSON on stdout. Diagnostics and errors go to stderr, and a
failure exits with a non-zero status.

## HTTP service

```bash
.build/release/argent-vision serve --port 8080 --confidence-threshold 0.50
```

Send the image as the raw request body:

```bash
curl --fail-with-body http://127.0.0.1:8080/detect \
  -H 'Content-Type: image/jpeg' \
  --data-binary @/tmp/deck.jpg
```

`POST /detect` returns the same JSON fields as the CLI (`image` is `"upload"`).
The default port is 8080. The server binds to `127.0.0.1`, processes one request
at a time, and closes each connection after responding. Stop it with Ctrl-C.
It is intended for local use; there is no authentication or TLS.

Requests require `Content-Length` and a nonempty body of at most 20 MiB. Use an
`image/*` content type or `application/octet-stream` (also the default when omitted).
Multipart forms and chunked transfer encoding are unsupported. Socket reads and
writes time out after 15 seconds of inactivity. Uploaded files are temporary and
removed after analysis.

Errors return JSON like `{"error":"Image could not be decoded."}` with an HTTP
status: 400 for malformed requests, 404 for unknown routes, 405 for other methods,
408 for incomplete requests that time out, 411 for missing length, 413 for oversized
images, 415 for unsupported content types, 417 for unsupported expectations,
422 for undecodable images, 431 for oversized headers, or 500 for analysis failures.

After `swift build`, run the HTTP integration checks from the repository root:

```bash
python3 apple-vision/tests/test_http.py deck.jpg
```

The image argument is optional; supplying it also checks that HTTP inference matches
the CLI. Set `ARGENT_VISION_BINARY` to test a binary built in another location.

## Vision compatibility diagnostics

The optional diagnostic executable runs face detection, rectangle detection,
each supported human-rectangle revision (up to revision 2), and classification
as independent requests:

```bash
.build/release/argent-vision-diagnostics /tmp/deck.jpg
```

Its JSON report includes the macOS version, supported human-request revisions,
and a separate success or error result for every request.
