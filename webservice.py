import logging
import os
import sys

import whisper
import torch
import ffmpeg

from fastapi import FastAPI, Request, Query, HTTPException

from urllib.parse import urlparse
from urllib.request import urlretrieve

def get_logger(logger_name):
    logger = logging.getLogger(logger_name)
    logger.setLevel(logging.DEBUG)
    handler = logging.StreamHandler(sys.stdout)
    handler.setLevel(logging.DEBUG)
    handler.setFormatter(
        logging.Formatter(
            '%(name)s [%(asctime)s] [%(levelname)s] %(message)s'))
    logger.addHandler(handler)
    return logger

logger = get_logger('transcription-service')

device = "cuda" if torch.cuda.is_available() else "cpu"
logger.debug('DEVICE:' + device)

app = FastAPI()

@app.get("/healthcheck", tags=["Endpoints"])
async def readiness_probe():
    return "Service ready."


@app.post("/transcribe_video", tags=["Endpoints"])
async def transcribe_video(request: Request):

    message = await request.json()
    logger.debug(f'Received request: {message}')

    input_rows = message['data']
    
    response_rows = []

    ########################################
    # Process Rows
    # Each row is a list of elements (r)
    # r[0] is the index
    # r[1] is the presigned url for accessing the file from the stage
    # r[2] is the function for Whisper (transcribe vs translate)
    # r[3] is the model to use for whister
    ########################################

    for r in input_rows:
        url = r[1]
        video_filename = urlparse(url).path.split('/')[-1]
        audio_filename = ''.join(video_filename.split('.')[:-1]) + '.wav'
        logger.debug(video_filename)
        logger.debug(audio_filename)

        whisper_task = r[2] if len(r) >= 3 else 'transcribe'
        logger.debug(whisper_task)

        whisper_model = r[3] if len(r) >= 4 else 'base'
        logger.debug(whisper_model)

        try: 
            urlretrieve(url, video_filename)
        except Exception as e:
            raise HTTPException(status_code=404, detail=f"Unable to retrieve file. {e}") 

        try: 
            input_file = ffmpeg.input(filename=video_filename)
            input_file.output(filename=audio_filename).run(overwrite_output=True)
            logger.debug('Video transcoded to Audio')

            # Load the Whisper model
            model = whisper.load_model(whisper_model, device=device, download_root='/whisper_models')

            # Transcribe and translate the audio
            logger.debug('Transcribe starting')
            result = model.transcribe(audio_filename, task=whisper_task)
            logger.debug('Transcribe ended')
        except Exception as e: 
            raise HTTPException(status_code=500, detail=f"Unable to process file. {e}") 
        
        finally:
            os.remove(video_filename) 
            os.remove(audio_filename)

        response_rows.append([r[0], result])
    return {"data": response_rows}
