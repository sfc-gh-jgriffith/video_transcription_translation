USE ROLE ACCOUNTADMIN;

/*******************************************************
 * create role, database, and warehouse
 ******************************************************/
CREATE ROLE video_transcription_role;
grant role video_transcription_role to role accountadmin;

CREATE DATABASE IF NOT EXISTS video_transcription_db;
GRANT OWNERSHIP ON DATABASE video_transcription_db TO ROLE video_transcription_role COPY CURRENT GRANTS;

CREATE OR REPLACE WAREHOUSE video_transcription_wh WITH
  WAREHOUSE_SIZE='X-SMALL';
GRANT USAGE ON WAREHOUSE video_transcription_wh TO ROLE video_transcription_role;

GRANT BIND SERVICE ENDPOINT ON ACCOUNT TO ROLE video_transcription_role;

/*******************************************************
 * set up external access for getting reacing the container
 ******************************************************/
CREATE OR REPLACE NETWORK RULE CONTAINER_NETWORK_RULE
    MODE = EGRESS
    TYPE = HOST_PORT
    VALUE_LIST = ('0.0.0.0:443','0.0.0.0:80');

CREATE OR REPLACE EXTERNAL ACCESS INTEGRATION CONTAINER_ACCESS_INTEGRATION
    ALLOWED_NETWORK_RULES = (CONTAINER_NETWORK_RULE)
    ENABLED = true;
grant usage on integration CONTAINER_ACCESS_INTEGRATION to role video_transcription_role;

/*******************************************************
 * Create compute pool 
 * Docs: https://docs.snowflake.com/en/sql-reference/sql/create-compute-pool
 ******************************************************/
CREATE COMPUTE POOL video_transcription_compute_pool
  MIN_NODES = 1
  MAX_NODES = 1
  INSTANCE_FAMILY = GPU_NV_S
  AUTO_SUSPEND_SECS = 300;

GRANT USAGE, MONITOR ON COMPUTE POOL video_transcription_compute_pool TO ROLE video_transcription_role;

show compute pools;

/******************************************************
 * Set up services for inference
 *****************************************************/
use role video_transcription_role;

USE DATABASE video_transcription_db;
USE WAREHOUSE video_transcription_wh;
-- set up schemas for app artifacts and data artifacts
CREATE SCHEMA IF NOT EXISTS APP_SCHEMA;
CREATE SCHEMA IF NOT EXISTS DATA_SCHEMA;

-- stage for video files
CREATE STAGE IF NOT EXISTS DATA_SCHEMA.VIDEO_STAGE
  DIRECTORY = ( ENABLE = true )
  ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE');

use schema APP_SCHEMA;

/******************************************************
 * Create stage for Whisper models
 * You can obtain the model files by running load_model
 * for each model size. The model files will be 
 * on your local machine (~/.cache/whisper on a Mac).
 * These can then be loaded to Snowflake using CLI
 * or the web UI. 
 *****************************************************/
CREATE STAGE IF NOT EXISTS APP_SCHEMA.WHISPER_MODELS
  DIRECTORY = ( ENABLE = true )
  ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE');

/******************************************************
 * Create stage image repository. 
 * Now you can push your image here.  
 *****************************************************/
CREATE IMAGE REPOSITORY IF NOT EXISTS APP_SCHEMA.IMAGE_REPOSITORY;

/******************************************************
 * Create a service to handle our requests. Alternatively,
 * this could be a job service that only runs until
 * all containers exist.
 * Docs: https://docs.snowflake.com/en/developer-guide/snowpark-container-services/overview
 *****************************************************/
CREATE SERVICE APP_SCHEMA.transcription_service
  IN COMPUTE POOL video_transcription_compute_pool
  FROM SPECIFICATION $$
    spec:
      containers:
      - name: transcribe
        image: /video_transcription_db/app_schema/image_repository/transcribe_video:latest
        env:
          SERVER_PORT: 9000
        readinessProbe:
          port: 9000
          path: /healthcheck
        resources:                        
            requests:
              memory: 12G
              nvidia.com/gpu: 1
              cpu: 5
            limits: 
              memory: 24G
              nvidia.com/gpu: 1
        volumeMounts:
        - name: whisper-model-stage
          mountPath: /whisper_models
      endpoints:
      - name: transcriptionendpoint
        port: 9000
        public: true
      volume:
      - name: whisper-model-stage
        source: "@whisper_models"
        uid: 1000
        gid: 1000
      $$
   MIN_INSTANCES=1
   MAX_INSTANCES=1
   EXTERNAL_ACCESS_INTEGRATIONS = (CONTAINER_ACCESS_INTEGRATION);

-- check status and logs
SELECT SYSTEM$GET_SERVICE_STATUS('transcription_service');
select SYSTEM$GET_SERVICE_LOGS('transcription_service', 0, 'transcribe');

/******************************************************
 * Create function to acces container through SQL
 * or Python
 *****************************************************/
CREATE OR REPLACE FUNCTION transcribe_video (video_url varchar, fuction varchar, model varchar)
RETURNS variant
SERVICE=transcription_service
ENDPOINT=transcriptionendpoint
AS '/transcribe_video';

/******************************************************
 * Inference Examples
 *****************************************************/

-- transcribe video and get the text telement from the whisper JSON response
select transcribe_video(get_presigned_url(
                            @data_schema.video_stage, relative_path), 
                        'transcribe', 
                        'medium') as transcription, 
       transcription:"text"::varchar as transcription_text,
       transcription:"segments"::varchar as transcription_segments
from directory(@data_schema.video_stage)
limit 1;

-- split segments to separate rows
with tmp as (select transcribe_video(get_presigned_url(
                            @data_schema.video_stage, relative_path), 
                        'transcribe', 
                        'medium') as transcription,   
from directory(@data_schema.video_stage)
limit 1)
select
    value:"start"::int as start_time,
    value:"end"::int as end_time,
    value:"text"::varchar as segment_text
from 
    tmp, 
    lateral flatten (input=> tmp.transcription:"segments")
;

-- translate video with whisper
select 
    transcribe_video(get_presigned_url(
                        @data_schema.video_stage, 
                        relative_path), 
                     'translate', 
                     'medium') as translation, 
*
from directory(@data_schema.video_stage)
where relative_path like 'At the Restaurant%';

-- transcribe video with whisper and translate using cortex functions
select transcribe_video(get_presigned_url(
                            @data_schema.video_stage, 
                            relative_path), 
                        'transcribe', 
                        'medium') as transcription,
       snowflake.cortex.translate(transcription:"text"::varchar, 'de', 'en') as translation,
       *
from directory(@data_schema.video_stage)
where relative_path like 'At the Restaurant%';