ARG BASE_IMAGE=python:3.10-slim-buster

# temp stage
FROM $BASE_IMAGE AS builder

RUN apt-get -qq update && \
    apt-get -qq --no-install-recommends install git && \
    rm -rf /var/lib/apt/lists/*

RUN pip install --upgrade pip && \
    pip wheel --no-cache-dir --no-deps --wheel-dir /wheels \
        torch \
        torchaudio \
        git+https://github.com/openai/whisper.git  \
        urllib3 \
        fastapi \
        gunicorn \
        uvicorn[standard] \
        ffmpeg-python


# final stage
FROM $BASE_IMAGE

RUN apt-get -qq update && \
    apt-get -qq --no-install-recommends install ffmpeg && \
    rm -rf /var/lib/apt/lists/*

COPY --from=builder /wheels /wheels
RUN pip install --upgrade pip && \
    pip install --no-cache /wheels/*

COPY webservice.py .
      
ENTRYPOINT ["gunicorn", "--bind", "0.0.0.0:9000", "--workers", "1", "--timeout", "0", "webservice:app", "-k", "uvicorn.workers.UvicornWorker"]