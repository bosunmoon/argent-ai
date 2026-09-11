"""Thin HTTP adapter for the existing argent-vision executable."""

import hmac
import json
import logging
import math
import os
import subprocess
import tempfile
import time
from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import Depends, FastAPI, File, Header, HTTPException, UploadFile
from fastapi.responses import Response

logger = logging.getLogger("uvicorn.error")
MAX_UPLOAD_BYTES = 10 * 1024 * 1024
BINARY = os.getenv(
    "ARGENT_VISION_BINARY", "/Users/mike/argent-ai/apple-vision/.build/argent-vision"
)
TIMEOUT = float(os.getenv("ARGENT_VISION_TIMEOUT", "10"))
API_KEY = os.getenv("ARGENT_VISION_API_KEY", "")
SIGNATURES = {"image/jpeg": (b"\xff\xd8\xff", ".jpg"),
              "image/png": (b"\x89PNG\r\n\x1a\n", ".png")}


@asynccontextmanager
async def lifespan(app: FastAPI):
    binary = Path(BINARY)
    if not binary.is_absolute() or not binary.is_file() or not os.access(binary, os.X_OK):
        logger.error("ARGENT_VISION_BINARY must be an absolute path to an executable file: %s", binary)
        raise RuntimeError("Invalid ARGENT_VISION_BINARY; see server logs")
    if not math.isfinite(TIMEOUT) or TIMEOUT <= 0:
        logger.error("ARGENT_VISION_TIMEOUT must be a positive finite number")
        raise RuntimeError("Invalid ARGENT_VISION_TIMEOUT")
    yield


app = FastAPI(title="argent-vision-api", version="0.1.0", lifespan=lifespan)


def authorize(x_api_key: str = Header(default="")):
    if API_KEY and not hmac.compare_digest(x_api_key.encode(), API_KEY.encode()):
        raise HTTPException(status_code=401, detail="Invalid or missing API key")


@app.get("/health")
def health():
    return {"status": "ok"}


@app.get("/version")
def version():
    return {"service": "argent-vision-api", "version": "0.1.0"}


def reject_constant(value):
    raise ValueError("Nonstandard JSON constant")


@app.post("/analyze", dependencies=[Depends(authorize)])
def analyze(image: UploadFile = File(...)):
    logger.info("Analysis request received: filename=%r content_type=%r", image.filename, image.content_type)
    temporary_path = None
    try:
        if image.content_type not in SIGNATURES:
            raise HTTPException(status_code=415, detail="Only JPEG and PNG images are supported")
        signature, suffix = SIGNATURES[image.content_type]
        first_chunk = image.file.read(64 * 1024)
        if not first_chunk.startswith(signature):
            raise HTTPException(status_code=415, detail="Image signature does not match content type")
        with tempfile.NamedTemporaryFile(prefix="argent-vision-", suffix=suffix, delete=False) as temporary:
            temporary_path = temporary.name
            logger.debug("Temporary image path: %s", temporary_path)
            size = 0
            chunk = first_chunk
            while chunk:
                size += len(chunk)
                if size > MAX_UPLOAD_BYTES:
                    raise HTTPException(status_code=413, detail="Image exceeds 10 MiB upload limit")
                temporary.write(chunk)
                chunk = image.file.read(64 * 1024)

        started = time.monotonic()
        try:
            result = subprocess.run(
                [BINARY, temporary_path], capture_output=True, timeout=TIMEOUT,
                check=False, shell=False,
            )
        except subprocess.TimeoutExpired as exc:
            logger.error("Vision timed out; stderr=%r", exc.stderr)
            raise HTTPException(status_code=504, detail="Vision analysis timed out") from exc
        except OSError as exc:
            logger.exception("Unable to execute Vision binary")
            raise HTTPException(status_code=500, detail="Unable to execute Vision binary; see server logs") from exc
        finally:
            logger.info("Vision subprocess elapsed_seconds=%.3f", time.monotonic() - started)

        logger.info("Vision subprocess return_code=%s", result.returncode)
        if result.returncode:
            logger.error("Vision failed; stderr=%r", result.stderr)
            raise HTTPException(status_code=500, detail={
                "error": "Vision analysis failed; see server logs",
                "return_code": result.returncode,
            })
        try:
            json.loads(result.stdout, parse_constant=reject_constant)
            result.stdout.decode("utf-8")
        except (ValueError, UnicodeError) as exc:
            logger.error("Vision returned invalid JSON; stderr=%r", result.stderr)
            raise HTTPException(status_code=502, detail="Vision returned invalid JSON") from exc
        return Response(content=result.stdout, media_type="application/json")
    finally:
        if temporary_path is not None:
            os.unlink(temporary_path)
        image.file.close()
